#!/usr/bin/env bash
# Repair helper: attempt to recover a USB capture device by resetting, unbinding/binding driver and restarting services.
# Usage: sudo ./repair.sh --vidpid 0bda:5821 [--hub 1-1.4] [--device /dev/video0]
MAINTENANCE_DESC="Full recovery: reset, rebind, restart services"
MAINTENANCE_ARGS="vidpid_and_hubport"

set -euo pipefail
VIDPID=""
DEVICE=""
HUBPORT=""
RESTART_SERVICES=true

while (( "$#" )); do
  case "$1" in
    --vidpid) VIDPID="$2"; shift 2;;
    --device) DEVICE="$2"; shift 2;;
    --hub) HUBPORT="$2"; shift 2;;
    --no-restart) RESTART_SERVICES=false; shift;;
    *) echo "Unknown option $1"; exit 2;;
  esac
done

if [ -z "$VIDPID" ] && [ -z "$DEVICE" ]; then
  echo "You must provide --vidpid or --device"
  exit 2
fi

if [ -z "$VIDPID" ]; then
  # attempt to find VIDPID for device
  if [ -n "$DEVICE" ]; then
    if [ -c "$DEVICE" ]; then
      VIDPID=$(udevadm info -q property -n "$DEVICE" | awk -F= '/ID_VENDOR_ID=/{v=$2}/ID_MODEL_ID=/{printf "%s:%s", v,$2} END {if(!v) exit 1}')
    fi
  fi
fi

# Optional: power cycle hub port if provided
if [ -n "$HUBPORT" ]; then
  if command -v uhubctl >/dev/null 2>&1; then
    echo "Power cycling hub port $HUBPORT (uhubctl required)"
    sudo uhubctl -l "$HUBPORT" -a 0 || true
    sleep 2
    sudo uhubctl -l "$HUBPORT" -a 1 || true
  else
    echo "uhubctl not available; skipping hub power cycle"
  fi
fi

# Try USB reset via usb_reset.sh (VID:PID or device)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "$VIDPID" ]; then
  echo "Attempting USB reset for $VIDPID"
  sudo "$SCRIPT_DIR/usb_reset.sh" "$VIDPID" || true
elif [ -n "$DEVICE" ]; then
  echo "Attempting USB reset for $DEVICE"
  sudo "$SCRIPT_DIR/usb_reset.sh" "$DEVICE" || true
fi

# Find sysfs device path and try unbind/bind driver
if [ -n "$VIDPID" ]; then
  V=$(echo "$VIDPID" | cut -d: -f1)
  P=$(echo "$VIDPID" | cut -d: -f2)
  SYSDEV=""
  for D in /sys/bus/usb/devices/*-*; do
    if [[ -f "$D/idVendor" && -f "$D/idProduct" ]]; then
      nv=$(cat "$D/idVendor")
      np=$(cat "$D/idProduct")
      if [[ "$nv" == "$V" && "$np" == "$P" ]]; then
        SYSDEV="$D"
        break
      fi
    fi
  done
else
  SYSDEV=$(udevadm info -q path -n "$DEVICE" 2>/dev/null | sed 's,^/devices/,,') || true
  SYSDEV=/sys/bus/usb/devices/$(basename "$SYSDEV")
fi

if [ -n "$SYSDEV" ] && [ -d "$SYSDEV" ]; then
  busid=$(basename "$SYSDEV")
  # Check if driver symlink actually exists
  if [ -L "$SYSDEV/driver" ]; then
    driver=$(basename $(readlink -f "$SYSDEV/driver"))
    echo "Unbinding $busid from $driver"
    echo -n "$busid" | sudo tee "$SYSDEV/driver/unbind" >/dev/null || true
    sleep 1
    echo -n "$busid" | sudo tee "$SYSDEV/driver/bind" >/dev/null || true
  else
    echo "No driver bound to $busid (device may be in broken state)"
  fi
else
  echo "Could not find device in sysfs"
fi

# Restart ffmpeg/service if requested
if [ "$RESTART_SERVICES" = true ]; then
  echo "Restarting services"
  sudo systemctl restart usb-capture-ffmpeg.service || true
  sudo systemctl restart usb-capture-monitor.service || true
fi

# Show recent dmesg
echo "Logs (dmesg) for last 30 lines after reset:"
sudo dmesg | tail -n 30

echo "Repair script finished."