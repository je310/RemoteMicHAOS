# USB Mic Stream (Home Assistant Add-on)

A minimal **Home Assistant OS (HAOS) add-on** that captures audio from a **USB microphone** (via Home Assistant’s PulseAudio) and publishes it as an **RTSP stream** using **FFmpeg** + **MediaMTX**.

This project exists to make **Android listening (VLC)** reliable, while keeping the add-on extremely easy to debug and tweak.

---

## What you get

- ✅ Capture from a USB mic through **PulseAudio** (`/run/audio/pulse.sock`)
- ✅ Publish as **RTSP** at a stable URL: `rtsp://<HA_IP>:<HOST_PORT>/<rtsp_path>`
- ✅ Heavy debug logging: devices, Pulse sources, config echo, FFmpeg command line
- ✅ Tuning knobs for smoothness vs latency + loudness (software gain)
- ✅ Internal RTSP server (MediaMTX) launched automatically inside the add-on

---

## Architecture

```
USB Mic -> HAOS Audio (PulseAudio) -> Add-on (FFmpeg) -> Add-on (MediaMTX) -> RTSP Client (Android/VLC/etc)
```

- **PulseAudio** comes from Home Assistant’s audio subsystem.
- **FFmpeg** reads the Pulse source and publishes as an RTSP *publisher*.
- **MediaMTX** hosts the RTSP server for your clients to connect to.

---

## Quick start

### 1) Install / run the add-on
Install the add-on as a local add-on (or from your repo), then start it.

Make sure the add-on has:
- `audio: true`
- `usb: true`
- access to `/dev/snd`

### 2) Configure the port mapping
Example `config.yaml` (add-on metadata):

```yaml
ports:
  8554/tcp: 19554

ports_description:
  19554/tcp: RTSP (host 19554 → container 8554), path /usbmic
```

- **Container listens** on `8554/tcp`
- Supervisor maps that to a **host port** (example `19554/tcp`)

### 3) Connect from Android (VLC)
Example (HA host IP `192.168.0.151`, host port `19554`):

```
rtsp://192.168.0.151:19554/usbmic
```

---

## Configuration options
These live under `options:` (and are validated by `schema:`).

### Common settings

| Option | Default | Notes |
|---|---:|---|
| `pulse_source` | `""` | If empty, uses PulseAudio **Default Source** |
| `rtsp_path` | `usbmic` | Path portion of RTSP URL |
| `rtsp_listen_port` | `8554` | Container port MediaMTX binds to |
| `rtsp_transport` | `tcp` | `tcp` recommended for Android stability |
| `sample_rate` | `48000` | Keep 48000 unless you have a reason |
| `channels` | `1` | Mono is usually correct for a mic |

### Codec / bitrate

| Option | Default | Notes |
|---|---:|---|
| `codec` | `opus` | `opus` or `aac` |
| `bitrate` | `64k` | Opus usually sounds fine at 48–96k |

Recommendation:
- Start with **Opus** for smoother low-bitrate audio.
- If your client struggles with Opus over RTSP, switch to **AAC**.

### Smoothness vs latency

| Option | Default | What it does |
|---|---:|---|
| `enable_smooth_timestamps` | `true` | Stabilizes timestamps to reduce “gaps” and DTS warnings |
| `aresample_async_ms` | `200` | Fills tiny timing holes (smoother) but adds latency |

Tuning guideline:
- More smooth: `aresample_async_ms: 300–600`
- Lower latency: `aresample_async_ms: 0–150` (may become choppy)

### Loudness

| Option | Default | Notes |
|---|---:|---|
| `gain_db` | `10` | Software gain in FFmpeg (0–30) |
| `enable_dynaudnorm` | `false` | Light dynamic normalization |

If it’s quiet: increase `gain_db` gradually (e.g. 12 → 15). Watch for distortion/clipping.

---

## Example options block

```yaml
options:
  pulse_source: "alsa_input.usb-Your_Mic_Name-00.mono-fallback"
  rtsp_path: "usbmic"
  rtsp_listen_port: 8554
  rtsp_transport: "tcp"

  sample_rate: 48000
  channels: 1

  codec: "opus"
  bitrate: "64k"

  enable_smooth_timestamps: true
  aresample_async_ms: 300

  gain_db: 12
  enable_dynaudnorm: false

  ffmpeg_loglevel: info
  restart_delay_sec: 2
```

---

## Troubleshooting

### “Port is already allocated”
Supervisor error like:

> Bind for 0.0.0.0:<port> failed: port is already allocated

Fix:
- Change your add-on host port mapping (e.g., map container 8554 → host 19554)
- Or stop whatever is using the old port

### VLC connects but there’s silence
Common causes: wrong Pulse source, mic muted/low volume, or client caching quirks.

Checklist:
- Add-on log prints `pactl list sources short` (confirm your source name)
- Confirm `pulse_source` matches
- Increase `gain_db` slightly
- Prefer `rtsp_transport: tcp`

### “Non-monotonic DTS” / “Queue input is backward in time”
This indicates timestamp jitter.

Mitigations:
- keep `enable_smooth_timestamps: true`
- increase `aresample_async_ms` (try 300–600)

### Audio choppy on Android even with caching
Try:
1. `rtsp_transport: tcp`
2. Increase `aresample_async_ms` to 300–600
3. Keep `sample_rate: 48000`
4. Lower bitrate (e.g. Opus 48k–64k) if CPU/network is stressed

---

## Notes on “mic sensitivity”
Many USB mics don’t expose hardware gain controls in a way HAOS can manage.

Practical approach here:
- Use Pulse source volume (the add-on attempts to raise it)
- Use FFmpeg `gain_db` and optionally `enable_dynaudnorm`

---

## Client URL recap
Given:
- container RTSP port `8554/tcp` → host `19554/tcp`
- `rtsp_path` = `usbmic`

Then:

```
rtsp://<HA_IP>:19554/usbmic
```

---

## License
Do whatever you want with it. If you share it, include this README so nobody has to rediscover the port mapping rules at 1am.