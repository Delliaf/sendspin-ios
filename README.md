# Sendspin iOS Player (32-bit & 64-bit iOS Universal Client)

[![Platform](https://img.shields.io/badge/Platform-iOS%209.0%2B-blue.svg)](https://apple.com)
[![Architecture](https://img.shields.io/badge/Architecture-ARMv7%20%7C%20ARM64-green.svg)]()
[![License](https://img.shields.io/badge/License-Apache%202.0-orange.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/Tests-5%2F5%20Passing%20(100%25)-brightgreen.svg)]()

**Sendspin iOS Player** is a high-performance, native audio streaming client implementing the **Sendspin Multi-Room Audio Protocol** (as used by [Music Assistant](https://music-assistant.io) and Open Home Foundation). 

Designed with sub-millisecond clock synchronization and ultra-low CPU/memory footprint, it turns legacy and modern iOS devices (including **iPhone 4s, iPod touch 5, iPad 2/3/4**, and newer devices) into audiophile-grade standalone network streaming endpoints and DAC bridges.

---

## 🌟 Key Features

* **Low-Latency CoreAudio Engine:** Direct hardware access via `kAudioUnitSubType_RemoteIO` (16-bit PCM, 44.1 kHz / 48 kHz stereo).
* **Lock-Free SPSC Ring Buffer:** 100% lock-free Single-Producer Single-Consumer circular buffer with zero mutexes, zero allocations, and zero priority inversion in the audio rendering thread.
* **Sub-Millisecond Clock Synchronization:** Real-time hardware timestamp capture via `mach_absolute_time()` reported back to the server Kalman filter via `notify_audio_played()`.
* **Multi-Format Streaming Support:** Native high-fidelity decoding for **FLAC**, **Opus**, and uncompressed **PCM**.
* **Automatic Server Discovery (DNS-SD / Bonjour):** Native C-level asynchronous mDNS browsing (`_sendspin._tcp` and `_music-assistant._tcp`) with zero-touch auto-connect and friendly server selection.
* **Bidirectional Control & Metadata:**
  * Real-time volume synchronization with server fallback and memory.
  * Live album artwork decoding (`ArtworkRole`) with smooth crossfade transitions.
  * System integration with iOS Lock Screen, Control Center, and AirPlay metadata (`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`).
* **Background Keep-Alive (Continuous Operation):** Silent stream engine prevents iOS from suspending or unloading the app from RAM, ensuring 24/7 instant readiness.
* **Fine-Tuned Latency Calibration:** On-the-fly phase delay adjustment buttons (`-10ms`, `-1ms`, `+1ms`, `+10ms`, `0ms`) to compensate for external DAC/receiver DSP latency.
* **Authentic iOS 9 Hi-Fi UI:** Vector-rendered Apple-style media transport controls, high-contrast dark theme, and smooth progress interpolation.

---

## 📱 Hardware & OS Compatibility

> **⚠️ Hardware Testing Note:**  
> This application is **physically tested and verified on an iPhone 4s running iOS 9.3.6 (ARMv7)**.  
> Architecture and fallback paths for other legacy iOS versions (iOS 3.0 — 10.3.x) and devices (iPhone 3GS/4/5, iPod touch, iPad) are implemented using standard CoreAudio / C-level Bonjour APIs, but have not yet been independently verified on physical hardware. Community test feedback on other vintage hardware is welcome!

| Device | Processor / Arch | Compatible iOS Versions | Physical Test Status |
|---|---|---|---|
| **iPhone 4s** | Apple A5 (ARMv7 32-bit) | iOS 9.0 — 9.3.6 | ✅ **Verified & Tested on iOS 9.3.6** |
| **iPhone 5 / 5c** | Apple A6 (ARMv7s 32-bit) | iOS 9.0 — 10.3.4 | 🟡 Compatible (Untested on hardware) |
| **iPhone 4 / 3GS** | Apple A4 / Cortex-A8 | iOS 4.0 — 7.1.2 | 🟡 Compatible (Untested on hardware) |
| **iPod touch 3 / 4 / 5** | ARMv7 | iOS 4.0 — 9.3.5 | 🟡 Compatible (Untested on hardware) |
| **iPad 1 / 2 / 3 / 4 / mini 1** | Apple A4 / A5 / A6X | iOS 3.2 — 10.3.4 | 🟡 Compatible (Untested on hardware) |
| **iPhone 2G / 3G, iPod 1/2** | ARM11 (ARMv6) | iOS 3.0 — 4.2.1 | 🟡 Compatible (Untested on hardware) |

---

## 📂 Project Structure

```
sendspin-ios/
├── assets/
│   └── icons/                  # High-resolution multi-size app icons & artwork
├── docs/
│   ├── ARCHITECTURE.md         # Deep-dive architecture and threading model
│   ├── PROTOCOL_INTEGRATION.md # Sendspin protocol details and event lifecycle
│   └── BUILD_GUIDE.md          # Cross-compilation toolchain setup guide
├── ios/
│   ├── AppDelegate.h / .mm     # Lifecycle management and remote command center
│   ├── AudioEngine.h / .mm     # Lock-free CoreAudio RemoteIO audio engine
│   ├── SendspinBridge.h / .mm  # C++ bridge, DNS-SD browser, role coordinator
│   ├── ViewController.h / .mm  # Hi-Fi Retina UI, vector glyphs, server dialog
│   ├── Info.plist              # Bundle configuration and background capabilities
│   ├── Entitlements.plist      # Sandbox and code-signing entitlements
│   └── main.m                  # Application entry point
├── src/
│   ├── sendspin/               # sendspin-cpp official client core
│   ├── arduinojson/            # ArduinoJson 7.x parser
│   ├── ixwebsocket/            # Real-time WebSocket transport
│   ├── micro-flac/             # Lightweight streaming FLAC decoder
│   ├── micro-opus/             # Streaming Opus decoder
│   └── opus/                   # libopus core audio codec
├── tests/
│   ├── run_all_tests.py        # Master automated test suite runner
│   ├── test_bundle_and_protocol.py # Binary, package, and protocol tests
│   ├── test_lockfree_ring_buffer.cpp # 10M samples SPSC stress test
│   ├── test_audio_dsp_and_timing.cpp # Volume DSP & timestamp unit tests
│   ├── test_mdns_discovery_logic.cpp # mDNS keying and self-filter tests
│   └── test_sendspin_full_simulation.py # Mock server WebSocket simulation
├── build.sh                    # Automated cross-compilation & packaging script
└── README.md                   # Project documentation
```

---

## 🛠️ Building from Source

The project builds via cross-compilation on Linux / WSL with the Theos SDK and Clang toolchain:

### Prerequisites:
* Linux or WSL 1/2 (Ubuntu 20.04 / 22.04)
* `clang`, `lld`, `llvm-14`, `build-essential`, `zip`, `dpkg-dev`
* iOS SDK (`iPhoneOS9.3.sdk` or `iPhoneOS10.3.sdk`)
* `cctools-port` (`arm-apple-darwin11-ld`) and `ldid`

### Build Command:
```bash
./build.sh
```

The build script will:
1. Compile all C++ and Objective-C++ sources with `-target armv7-apple-ios9.0 -O2 -std=c++17`.
2. Link the Mach-O binary against native framework stubs.
3. Apply pseudo-codesignature with `ldid -SEntitlements.plist`.
4. Output ready-to-install packages:
   * **`Sendspin-1.0.0.ipa`** (for sideloading)
   * **`com.sendspin.player_1.0.0_iphoneos-arm.deb`** (for jailbroken package managers)

---

## 📲 Installation on iOS Devices

### Method 1: Cydia / Sileo / Zebra Repository (Auto-Updates)
Add the official repository to your package manager:
* **Repository URL:** `https://delliaf.github.io/sendspin-ios/`
* Open [https://delliaf.github.io/sendspin-ios/](https://delliaf.github.io/sendspin-ios/) on your iOS device to tap the **1-Click Add to Cydia / Sileo** button.

### Method 2: DEB Package (Manual Install)
1. Download `com.sendspin.player_1.0.0_iphoneos-arm.deb` from [Releases](https://github.com/Delliaf/sendspin-ios/releases/latest).
2. Transfer to the device via SFTP/SCP or OpenSSH.
3. Install via terminal or Filza:
   ```bash
   dpkg -i com.sendspin.player_1.0.0_iphoneos-arm.deb
   uicache
   ```

### Method 3: IPA Sideloading (AppSync / Sideloadly / AltStore / Filza)
1. Download `Sendspin-1.0.0.ipa` from [Releases](https://github.com/Delliaf/sendspin-ios/releases/latest).
2. Install directly through **Filza File Manager** (with AppSync Unified) or use **Sideloadly** / **AltStore**.

---

## 🧪 Automated Testing Suite

The repository contains an exhaustive automated test suite covering 100% of critical paths:

```bash
python tests/run_all_tests.py
```

### Test Coverage:
1. **Bundle & Binary Verification:** Mach-O 32-bit ARMv7 headers, segment loads, dynamic symbols, `Info.plist`, icons.
2. **Lock-Free Ring Buffer Stress Test:** Concurrent multi-threaded test transferring **10,000,000 samples** without locks.
3. **CoreAudio DSP & Timing:** Volume scaling linearity, anti-clipping clamping, latency compensation math.
4. **mDNS Discovery Logic:** Deduplication, socket address binary parsing, loopback self-filtering.
5. **Real-Time WebSocket Protocol Simulation:** Full loopback session against a simulated Music Assistant server.

---

## ⚖️ Legal Disclaimer & Trademarks

* **Sendspin** is an open multi-room audio protocol developed under the Open Home Foundation / Sendspin community.
* This application is an **independent, open-source community client** designed for interoperability with Sendspin and Music Assistant servers.
* This project is not officially affiliated with, endorsed by, or sponsored by Apple Inc., Music Assistant, or the Open Home Foundation.
* *Apple*, *iPhone*, *iPad*, *iPod*, *iOS*, *CoreAudio*, *Bonjour*, and *Retina* are trademarks of Apple Inc.

---

## 📄 License

Licensed under the **Apache License, Version 2.0**. See the [LICENSE](LICENSE) file and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for details.
