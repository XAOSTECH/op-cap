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
    *) echo "Unknown option $1"; exit 2;;
  esac
done

if [ -z "$VIDPID" ]; then
  echo "Warning: VID:PID not provided; using device to watch only ($DEVNODE)" >&2
fi

echo "Watching $DEVNODE for connection (VIDPID=$VIDPID) -- will try $MAX_RESET_ATTEMPTS resets if it goes down"

while true; do
  if [ -c "$DEVNODE" ]; then
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
          sleep 1
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
      # Wait for the device to reappear (up to 30s) then kill OBS so the wrapper restarts it
      _w=0
      while ! [ -c "$DEVNODE" ] && [ "$_w" -lt 30 ]; do sleep 1; _w=$((_w+1)); done
      if [ -c "$DEVNODE" ]; then
        echo "Device $DEVNODE back after reset. Signalling OBS to restart..."
        pkill -TERM -f 'obs.*--safe-mode' 2>/dev/null || true
      else
        echo "Device $DEVNODE did not reappear within 30s after reset."
      fi
    elif [ -f "$(dirname "$0")/../ffmpeg/feed.sh" ]; then
      echo "Starting feed ($FFMPEG_SERVICE)"
      systemctl start "$FFMPEG_SERVICE" || bash "$(dirname "$0")/../ffmpeg/feed.sh" &
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
