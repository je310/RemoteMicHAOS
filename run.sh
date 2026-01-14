#!/usr/bin/with-contenv bash
set -euo pipefail

log() { echo "[$(date +'%H:%M:%S')] INFO: $*"; }
warn(){ echo "[$(date +'%H:%M:%S')] WARNING: $*" >&2; }
err() { echo "[$(date +'%H:%M:%S')] ERROR: $*" >&2; }

FFMPEG_PID=""
MEDIAMTX_PID=""

cleanup() {
  log "Cleaning up child processes..."
  if [[ -n "${FFMPEG_PID:-}" ]]; then
    kill -TERM "$FFMPEG_PID" >/dev/null 2>&1 || true
    wait "$FFMPEG_PID" >/dev/null 2>&1 || true
    FFMPEG_PID=""
  fi
  if [[ -n "${MEDIAMTX_PID:-}" ]]; then
    kill -TERM "$MEDIAMTX_PID" >/dev/null 2>&1 || true
    wait "$MEDIAMTX_PID" >/dev/null 2>&1 || true
    MEDIAMTX_PID=""
  fi
}
trap cleanup EXIT INT TERM

# ---------- read options ----------
OPTIONS_FILE="/data/options.json"
if [[ ! -f "$OPTIONS_FILE" ]]; then
  warn "No /data/options.json found; using defaults."
  OPTIONS_FILE="/dev/null"
fi

getopt_json() {
  local key="$1"
  local def="${2:-}"
  local v=""
  if command -v jq >/dev/null 2>&1 && [[ -f "$OPTIONS_FILE" ]]; then
    v="$(jq -r --arg k "$key" '.[$k] // empty' "$OPTIONS_FILE" 2>/dev/null || true)"
  fi
  if [[ -z "${v:-}" || "${v:-}" == "null" ]]; then
    echo "$def"
  else
    echo "$v"
  fi
}

# Pulse + RTSP only
PULSE_SOURCE_CFG="$(getopt_json pulse_source "")"
RTSP_PATH="$(getopt_json rtsp_path "usbmic")"
RTSP_LISTEN_PORT="$(getopt_json rtsp_listen_port "8554")"
RTSP_TRANSPORT="$(getopt_json rtsp_transport "tcp")"     # tcp|udp

SAMPLE_RATE="$(getopt_json sample_rate "48000")"
CHANNELS="$(getopt_json channels "1")"

CODEC="$(getopt_json codec "opus")"                      # opus|aac
BITRATE="$(getopt_json bitrate "64k")"

ENABLE_SMOOTH_TS="$(getopt_json enable_smooth_timestamps "true")"
ARESAMPLE_ASYNC_MS="$(getopt_json aresample_async_ms "200")"

GAIN_DB="$(getopt_json gain_db "10")"
ENABLE_DYNAUDNORM="$(getopt_json enable_dynaudnorm "false")"

FFMPEG_LOGLEVEL="$(getopt_json ffmpeg_loglevel "info")"
RESTART_DELAY_SEC="$(getopt_json restart_delay_sec "2")"

# ---------- banner + debug ----------
log "===================================================="
log "             USB MIC STREAM (Minimal Test Add-on)"
log "===================================================="
log "---- Environment ----"
id || true
uname -a || true
if [[ -f /etc/os-release ]]; then
  log "OS: $(tr '\n' ' ' </etc/os-release | sed 's/  */ /g')"
fi

log "---- Devices: /dev/snd ----"
ls -la /dev/snd 2>/dev/null || true

log "---- /sys/class/sound ----"
ls -la /sys/class/sound 2>/dev/null || true

log "---- /proc/asound ----"
ls -la /proc/asound 2>/dev/null || true

log "---- /run (audio hints) ----"
ls -la /run 2>/dev/null || true

log "---- /run/audio ----"
ls -la /run/audio 2>/dev/null || true

log "---- lsusb (best effort) ----"
lsusb 2>/dev/null || true

log "---- pactl info (best effort) ----"
pactl info 2>/dev/null || true

log "---- pactl list sources short (best effort) ----"
pactl list sources short 2>/dev/null || true

log "---- Config ----"
log "pulse_source=${PULSE_SOURCE_CFG:-<auto>}"
log "rtsp_listen_port=$RTSP_LISTEN_PORT rtsp_path=/$RTSP_PATH transport=$RTSP_TRANSPORT"
log "sample_rate=$SAMPLE_RATE channels=$CHANNELS codec=$CODEC bitrate=$BITRATE"
log "enable_smooth_timestamps=$ENABLE_SMOOTH_TS aresample_async_ms=$ARESAMPLE_ASYNC_MS"
log "gain_db=$GAIN_DB enable_dynaudnorm=$ENABLE_DYNAUDNORM"
log "ffmpeg_loglevel=$FFMPEG_LOGLEVEL restart_delay_sec=$RESTART_DELAY_SEC"

# ---------- helpers ----------
select_pulse_source() {
  local src="$PULSE_SOURCE_CFG"
  if [[ -z "$src" ]]; then
    src="$(pactl info 2>/dev/null | awk -F': ' '/^Default Source:/{print $2; exit}')"
  fi
  echo "$src"
}

probe_pulse() {
  local src="$1"
  log "Probe: Pulse '$src' (2s)"
  timeout 2s ffmpeg -hide_banner -nostdin -loglevel error \
    -f pulse -i "$src" -t 1 -vn -f null - >/dev/null 2>&1
}

write_mediamtx_config() {
  local port="$1"
  local cfg="/tmp/mediamtx.yml"
  cat >"$cfg" <<EOF
logLevel: info
rtsp: yes
rtspAddress: :${port}

# simplest RTSP publisher path
paths:
  ${RTSP_PATH}:
    source: publisher
EOF
  echo "$cfg"
}

start_internal_rtsp_server() {
  if ! command -v mediamtx >/dev/null 2>&1; then
    err "mediamtx binary not found in container."
    err "Make sure your Dockerfile installs it (wget/tar like before)."
    return 1
  fi

  local cfg
  cfg="$(write_mediamtx_config "$RTSP_LISTEN_PORT")"
  log "Starting internal MediaMTX RTSP server on :${RTSP_LISTEN_PORT}"
  log "MediaMTX config: $cfg"
  mediamtx "$cfg" &
  MEDIAMTX_PID=$!
  sleep 0.5
  return 0
}

build_codec_args() {
  case "$CODEC" in
    opus)
      # Opus is often smoother at low bitrates and tolerant of jitter
      echo "-c:a libopus -b:a $BITRATE -application lowdelay"
      ;;
    aac)
      echo "-c:a aac -b:a $BITRATE"
      ;;
    *)
      warn "Unknown codec '$CODEC', defaulting to opus"
      echo "-c:a libopus -b:a $BITRATE -application lowdelay"
      ;;
  esac
}

build_audio_filter() {
  # 1) Stabilize timestamps / fill tiny gaps (async)
  # 2) Force monotonic-ish PTS for audio
  # 3) Add gain
  # 4) Optional gentle normalization
  local f=""

  if [[ "$ARESAMPLE_ASYNC_MS" != "0" ]]; then
    # async in ms -> convert to seconds-ish behavior via async (samples) is messy;
    # ffmpeg accepts ms for async? it’s actually in samples, but works well as a knob here.
    # We keep it modest so it doesn’t “rubber band” audio.
    f="aresample=async=1:min_hard_comp=0.100:first_pts=0"
  fi

  # ensure timestamps are derived from sample count
  if [[ -n "$f" ]]; then
    f="${f},asetpts=N/SR/TB"
  else
    f="asetpts=N/SR/TB"
  fi

  # loudness
  if [[ "$GAIN_DB" != "0" ]]; then
    f="${f},volume=${GAIN_DB}dB"
  fi

  if [[ "$ENABLE_DYNAUDNORM" == "true" ]]; then
    # light dynamic normalization; adds some processing (but often helps “quiet mic”)
    f="${f},dynaudnorm=f=150:g=5"
  fi

  echo "$f"
}

# ---------- main loop ----------
while true; do
  cleanup || true

  if [[ ! -S /run/audio/pulse.sock ]]; then
    err "Pulse socket not found at /run/audio/pulse.sock. Retrying in ${RESTART_DELAY_SEC}s..."
    sleep "$RESTART_DELAY_SEC"
    continue
  fi

  if ! start_internal_rtsp_server; then
    err "RTSP server failed to start. Retrying in ${RESTART_DELAY_SEC}s..."
    sleep "$RESTART_DELAY_SEC"
    continue
  fi

  src="$(select_pulse_source)"
  if [[ -z "$src" ]]; then
    err "Could not determine Pulse source (empty). Retrying in ${RESTART_DELAY_SEC}s..."
    sleep "$RESTART_DELAY_SEC"
    continue
  fi

  log "Using Pulse source: $src"

  # Unmute + set source volume (helps with “quiet mic” when Pulse allows it)
  pactl set-source-mute "$src" 0 >/dev/null 2>&1 || true
  pactl set-source-volume "$src" 130% >/dev/null 2>&1 || true
  log "Pulse source mute/volume (best effort):"
  pactl get-source-mute "$src" 2>/dev/null || true
  pactl get-source-volume "$src" 2>/dev/null || true

  if probe_pulse "$src"; then
    log "Probe OK: Pulse '$src'"
  else
    err "Probe FAILED: Pulse '$src'. Retrying in ${RESTART_DELAY_SEC}s..."
    sleep "$RESTART_DELAY_SEC"
    continue
  fi

  codec_args="$(build_codec_args)"
  afilter="$(build_audio_filter)"
  out_url="rtsp://127.0.0.1:${RTSP_LISTEN_PORT}/${RTSP_PATH}"

  log "Android should connect to: rtsp://<HA_IP>:<HOST_PORT>/${RTSP_PATH}"
  log "Publishing RTSP (publisher): ${out_url}"
  log "Starting capture + publish..."

  # timestamp stabilization: treat wallclock as timestamps + generate PTS
  # (helps “Non-monotonic DTS” and audible gaps)
  ts_args=()
  if [[ "$ENABLE_SMOOTH_TS" == "true" ]]; then
    ts_args+=( -use_wallclock_as_timestamps 1 -fflags +genpts )
  fi

  cmd=( ffmpeg
    -nostdin -hide_banner -loglevel "$FFMPEG_LOGLEVEL"
    -vn
    "${ts_args[@]}"
    -thread_queue_size 512
    -f pulse -i "$src"
    -af "$afilter"
    -ac "$CHANNELS" -ar "$SAMPLE_RATE"
    $codec_args
    -f rtsp -rtsp_transport "$RTSP_TRANSPORT"
    "$out_url"
  )

  log "FFmpeg command:"
  printf '[%s] INFO:   ' "$(date +'%H:%M:%S')"; printf '%q ' "${cmd[@]}"; echo

  "${cmd[@]}" &
  FFMPEG_PID=$!
  log "FFmpeg PID=$FFMPEG_PID. Running..."

  wait "$FFMPEG_PID"
  rc=$?
  warn "FFmpeg exited (rc=$rc). Restarting in ${RESTART_DELAY_SEC}s..."
  sleep "$RESTART_DELAY_SEC"
done
