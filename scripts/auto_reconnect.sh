#!/usr/bin/env bash
# Monitor a v4l2 capture device; on disconnect, reset and rebind USB, then restart the FFmpeg service or OBS.
# Usage: sudo ./auto_reconnect.sh --vidpid 1a2b:3344 --device /dev/video0 [--feed-service svc] [--restart-obs]

set -euo pipefail

VIDPID=""
DEVNODE="/dev/video0"
FFMPEG_SERVICE="usb-capture-ffmpeg.service"
RESTART_OBS=0
CHECK_INTERVAL=2
RESET_COUNT=0
MAX_RESET_ATTEMPTS=3
RESTART_SENTINEL=""  # optional path; touched before OBS is killed so wrapper skips --safe-mode

while (( "$#" )); do
  case "$1" in
    --vidpid)
      VIDPID="$2"; shift 2;;
    --device)
      DEVNODE="$2"; shift 2;;
    --ffmpeg-service)
      FFMPEG_SERVICE="$2"; shift 2;;
    --restart-obs)
      RESTART_OBS=1; shift;;
    --restart-sentinel)
      RESTART_SENTINEL="$2"; shift 2;;
    *) echo "Unknown option $1"; exit 2;;
  esac
done

# Derive VIDPID from udevadm if not provided (needed for USB reset)
if [ -z "$VIDPID" ] && [ -c "$DEVNODE" ]; then
  _v=$(udevadm info -q property -n "$DEVNODE" 2>/dev/null | awk -F= '/^ID_VENDOR_ID=/{print $2;exit}')
  _p=$(udevadm info -q property -n "$DEVNODE" 2>/dev/null | awk -F= '/^ID_MODEL_ID=/{print $2;exit}')
  [ -n "$_v" ] && [ -n "$_p" ] && VIDPID="${_v}:${_p}" && echo "Derived VID:PID from device: $VIDPID" >&2
fi

if [ -z "$VIDPID" ]; then
  echo "Warning: VID:PID not available; USB reset will be skipped ($DEVNODE)" >&2
fi

echo "Watching $DEVNODE (VIDPID=${VIDPID:-none}) -- will try $MAX_RESET_ATTEMPTS resets if it goes down"

while true; do
  # Use sysfs to detect real kernel-level disconnect; /dev/videoN persists on driver-only failures
  _devname=$(basename "$DEVNODE")
  if [ -d "/sys/class/video4linux/$_devname" ]; then
    # OK; reset counter
    if [ "$RESET_COUNT" -ne 0 ]; then
      echo "Device returned. Reset count reset"
    fi
    RESET_COUNT=0
  else
    echo "$(date) - Device $DEVNODE is gone. Attempting to restart."
    # try graceful restart: restart ffmpeg service and re-detect
    if [ "$RESTART_OBS" -eq 0 ] && systemctl is-active --quiet "$FFMPEG_SERVICE"; then
      echo "Stopping $FFMPEG_SERVICE"
      systemctl stop "$FFMPEG_SERVICE" || true
    fi

    # If VIDPID available, attempt usb reset via helper
    if [ -n "$VIDPID" ]; then
      echo "Attempting USB reset for $VIDPID"
      sudo bash "$(dirname "$0")/usb_reset.sh" "$VIDPID" || true
    fi

    # Optional: attempt driver unbind/bind (requires kernel driver info)
    # We'll search for USB device path using udevadm.
    if [ -n "$VIDPID" ]; then
      V=$(echo "$VIDPID" | cut -d: -f1)
      P=$(echo "$VIDPID" | cut -d: -f2)
      device_sys=$(ls -1 /sys/bus/usb/devices/* | while read D; do if [[ -f $D/idVendor && -f $D/idProduct ]]; then v=$(cat $D/idVendor); p=$(cat $D/idProduct); if [[ "$v" == "$V" && "$p" == "$P" ]]; then echo "$D"; fi; fi; done | head -n1)
      if [ -n "$device_sys" ]; then
        drv=$(basename "$(readlink -f $device_sys/driver 2>/dev/null || true)")
        busid=$(basename "$device_sys")
        echo "Device sys path: $device_sys driver: $drv busid: $busid"
        if [ -n "$drv" ]; then
          echo "Unbinding $busid from $drv"
          echo -n "$busid" > "$device_sys/driver/unbind" 2>/dev/null || true
          sleep 0.3
          echo -n "$busid" > "$device_sys/driver/bind" 2>/dev/null || true
          echo "Rebind attempted"
        fi
      fi
    fi

    (( RESET_COUNT++ ))
    if (( RESET_COUNT >= MAX_RESET_ATTEMPTS )); then
      echo "Reached max reset attempts. Attempting 'repair' helper (usb reset + rebind + restart services)."
      # Call our repair helper which will attempt a hub power cycle, usb reset, rebind and restart of services
      if [ -f "$(dirname "$0")/repair.sh" ]; then
        sudo bash "$(dirname "$0")/repair.sh" --vidpid "$VIDPID" --device "$DEVNODE" || true
      fi
      echo "Repair attempt done. Waiting for manual intervention if it failed."
      # optionally escalate: power cycle hub or run uhubctl (not included) or ask for alert
      # Sleep longer before retrying
      sleep 30
      RESET_COUNT=0
    fi

    # Restart the capture pipeline
    if [ "$RESTART_OBS" -eq 1 ]; then
      # Wait for a v4l2 device associated with the VID:PID to reappear, max 4 s.
      # We scan by VID:PID rather than the original /dev/videoN name because USB re-enumeration can produce a different minor number after a reset.
      _w=0
      _found_devname=""
      while [ "$_w" -lt 4 ] && [ -z "$_found_devname" ]; do
        sleep 1; _w=$((_w+1))
        if [ -n "$VIDPID" ]; then
          _vid="${VIDPID%:*}"; _pid="${VIDPID#*:}"
          _found_devname=$(for _d in /sys/bus/usb/devices/*/idVendor; do
            _dir=$(dirname "$_d")
            [ "$(cat "$_dir/idVendor" 2>/dev/null)" = "$_vid" ] || continue
            [ "$(cat "$_dir/idProduct" 2>/dev/null)" = "$_pid" ] || continue
            find "$_dir" -maxdepth 6 -name "video*" -path "*/video4linux/*" 2>/dev/null | head -n1
          done | head -n1 | xargs -r basename)
        else
          [ -d "/sys/class/video4linux/$(basename "$DEVNODE")" ] && \
            _found_devname=$(basename "$DEVNODE")
        fi
      done
      if [ -n "$_found_devname" ]; then
        echo "Device returned as /dev/$_found_devname after ${_w}s" >&2
      else
        echo "Device did not reappear within 4s — signalling OBS to restart anyway" >&2
      fi
      # Let the obs-safe-launch wrapper know this is an intentional restart so it can skip --safe-mode and use a shorter recovery timeout.
      [ -n "$RESTART_SENTINEL" ] && { touch "$RESTART_SENTINEL" 2>/dev/null || true; }
      # Kill OBS — match broadly regardless of whether --safe-mode is currently active
      echo "Signalling OBS to restart (device ${DEVNODE} $( [ -n "$_found_devname" ] && echo 'back' || echo 'still absent'))..." >&2
      _obs_pid=$(pgrep -n -f 'obs.*--disable-missing-files-check' 2>/dev/null || pgrep -xn obs 2>/dev/null || echo "")
      if [ -n "$_obs_pid" ]; then
        kill -TERM "$_obs_pid" 2>/dev/null || true
        sleep 1
        # Force-kill if still alive (e.g. streaming-confirm dialog showed up despite ini flag)
        kill -0 "$_obs_pid" 2>/dev/null && kill -KILL "$_obs_pid" 2>/dev/null || true
      fi
    elif [ -f "$(dirname "$0")/../ffmpeg/feed.sh" ]; then
      echo "Starting feed ($FFMPEG_SERVICE)"
      systemctl start "$FFMPEG_SERVICE" || bash "$(dirname "$0")/../ffmpeg/feed.sh" &
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
