#!/usr/bin/env bash
# Detect a USB capture device and print helpful info
# Usage: sudo ./detect_device.sh [VID:PID]
MAINTENANCE_DESC="Detect and display USB video device info"
MAINTENANCE_ARGS="vidpid_optional"

set -euo pipefail
VIDPID=${1:-}

which lsusb >/dev/null || { echo "Please install usbutils (lsusb)"; exit 1; }

if [ -z "$VIDPID" ]; then
  echo "Listing USB video devices (lsusb and v4l2-ctl output):"
  echo
  lsusb | grep -i -E 'camera|video|hdmi|capture|264|551|544' || true
  echo
  if command -v v4l2-ctl >/dev/null 2>&1; then
    echo "v4l2 devices and their sysfs path:"; echo
    v4l2-ctl --list-devices || true
  else
    echo "v4l2-ctl not found; install v4l-utils (sudo apt install v4l-utils) to list devices"
  fi
  exit 0
fi

VID=$(echo "$VIDPID" | cut -d: -f1)
PID=$(echo "$VIDPID" | cut -d: -f2)

# Show matching lsusb lines
echo "Searching devices matching $VID:$PID in lsusb:"
lsusb | grep -i "$VID:$PID" || true

echo
for dev in /sys/bus/usb/devices/*; do
  if [ -f "$dev/idVendor" ]; then
    v=$(cat "$dev/idVendor")
    p=$(cat "$dev/idProduct")
    if [ "$v" == "$VID" ] && [ "$p" == "$PID" ]; then
      echo "Found device: $dev"
      echo "  idVendor=$v idProduct=$p"
      echo "  product name: $(cat $dev/product 2>/dev/null || echo N/A)"
      echo "  manufacturer: $(cat $dev/manufacturer 2>/dev/null || echo N/A)"
      echo "  driver: $(basename $(readlink -f $dev/driver 2>/dev/null) || echo N/A)"
      echo "  authorized: $(cat $dev/authorized 2>/dev/null || echo N/A)"
      echo "  power/control: $(cat $dev/power/control 2>/dev/null || echo N/A)"

      # related video devices
      echo "  Video devices (scan /dev):"
      for v in /dev/video*; do
        udevadm info -q property -n "$v" 2>/dev/null | grep -i "ID_VENDOR_ID=\|ID_MODEL_ID=\|ID_USB_DRIVER=\|ID_PATH=" || true
      done
    fi
  fi
done
