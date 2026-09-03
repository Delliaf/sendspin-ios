# Sendspin iOS Player — Architecture Specification

## 1. System Overview

Sendspin iOS Player is built around three isolated concurrent execution domains:

```
┌─────────────────────────────────────────────────────────────┐
│                      iOS Runtime                            │
├─────���────────────────────────┬──────────────────────────────┤
│ 1. Network & Protocol Domain │ 2. Audio Render Domain       │
│    (sendspin-cpp / POSIX)    │    (CoreAudio HAL Real-time) │
│  - WebSocket Client/Server   │  - RemoteIO AudioUnit        │
│  - DNS-SD Browser (dns_sd.h) │  - 100% Lock-Free SPSC Buffer│
│  - FLAC/Opus/PCM Decoders    │  - Volume Scaling & Clamping │
│  - Time Synchronization      │  - Hardware Timestamping     │
├──────────────────────────────┴──────────────────────────────┤
│ 3. User Interface & System Integration Domain (Main Thread) │
│  - Retina 3.5" Hi-Fi Interface (UIKit / Vector Glyphs)      │
│  - MPNowPlayingInfoCenter & MPRemoteCommandCenter           │
│  - mDNS Server Selection & Latency Calibration              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Component Details

### 2.1 Audio Engine (`AudioEngine.mm`)
* **Audio Unit Type:** `kAudioUnitType_Output` / `kAudioUnitSubType_RemoteIO`.
* **Output Format:** 16-bit Signed Linear PCM, Interleaved Stereo (44.1 kHz / 48 kHz).
* **Buffer Mechanism:** `LockFreeAudioRingBuffer` — a Single-Producer Single-Consumer (SPSC) circular buffer with power-of-two capacity (1,048,576 bytes) and atomic read/write indices with acquire-release memory barriers.
* **Real-time Safety:** The render callback `CoreAudioRenderCallback` performs zero memory allocations, zero system locks (`std::mutex`), and zero blocking calls.
* **Timestamp Reporting:** Uses `mach_absolute_time()` converted to microseconds to report exact DAC output timing to `PlayerRole::notify_audio_played()`.

### 2.2 Sendspin Bridge (`SendspinBridge.mm`)
* **Role Management:** Configures `PlayerRole`, `ControllerRole`, `MetadataRole`, and `ArtworkRole`.
* **Server/Client Modes:**
  * Publishes `_sendspin._tcp` on port 8928 via `DNSServiceRegister`.
  * Asynchronously discovers `_sendspin._tcp` and `_music-assistant._tcp` on port 8927 via `DNSServiceBrowse`.
* **Now Playing Synchronization:** Dispatches track titles, artist, album, duration, and artwork directly to `MPNowPlayingInfoCenter`.

### 2.3 User Interface (`ViewController.mm`)
* **Layout:** Optimized for iPhone 3.5" Retina displays (320x480 pt / 640x960 px).
* **Vector Icons:** Anti-aliased Apple-style media glyphs rendered via CoreGraphics.
* **Interpolated Scrubber:** 5 Hz timer provides smooth elapsed time progress between metadata packet bursts.
