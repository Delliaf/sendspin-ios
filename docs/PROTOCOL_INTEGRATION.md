# Sendspin Protocol Integration & Lifecycle

## 1. Connection Establishment

Sendspin supports two connection topologies:

### 1.1 Server-Initiated (Standard Mode)
1. **Player Broadcast:** The iOS client advertises an mDNS service:
   * Service Type: `_sendspin._tcp`
   * Port: `8928`
   * TXT Record: `path=/sendspin`, `name=<PlayerName>`
2. **Server Discovery:** Music Assistant / Sendspin Server discovers the player via mDNS.
3. **Inbound Connection:** Server opens a WebSocket connection to `ws://<ios_ip>:8928/sendspin`.

### 1.2 Client-Initiated Mode
1. **Server Discovery:** iOS client discovers server advertising `_sendspin._tcp` / `_music-assistant._tcp` on port `8927`.
2. **Outbound Connection:** iOS client dials `ws://<server_ip>:8927/sendspin`.

---

## 2. Handshake Sequence

```
Client (iOS Player)                        Server (Music Assistant)
        │                                             │
        │ ◄────────── server/hello (roles) ───────────│
        │                                             │
        │ ─────────── client/hello (formats) ────────►│
        │                                             │
        │ ◄────────── server/state (vol/delay) ───────│
        │                                             │
        │ ─────────── client/time ───────────────────►│
        │ ◄────────── server/time ────────────────────│ (Repeated 3x burst)
        │                                             │
        │ ◄────────── stream/start (FLAC/Opus) ───────│
        │ ◄────────── metadata (title, art, dur) ─────│
        │ ◄────────── binary audio frames ────────────│
        │                                             │
        │ ─────────── notify_audio_played() ─────────►│
```

---

## 3. Clock Synchronization & Jitter Buffer

1. **Burst Sync:** Time synchronization packets (`client/time` / `server/time`) calculate round-trip latency and clock drift.
2. **Kalman Filter:** Server-side Kalman filter tracks phase and frequency error.
3. **Playback Priming:** A 50ms startup silence buffer ensures jitter immunity before real-time PCM rendering begins.
