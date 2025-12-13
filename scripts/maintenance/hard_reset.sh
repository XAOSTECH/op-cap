#!/usr/bin/env bash
# Hard reset USB device: unbind driver, wait, rebind
# Usage: ./hard_reset.sh VID:PID
MAINTENANCE_DESC="Hard reset USB device (unbind/rebind driver)"
MAINTENANCE_ARGS="vidpid"

set -euo pipefail

VIDPID=${1:-}

if [ -z "$VIDPID" ]; then
  echo "Usage: $0 VID:PID (e.g., 3188:1000)"
  exit 1
fi

VID=$(echo "$VIDPID" | cut -d: -f1)
PID=$(echo "$VIDPID" | cut -d: -f2)

echo "Finding device $VIDPID..."

SYSDEV=""
for D in /sys/bus/usb/devices/*; do
  if [ -f "$D/idVendor" ] && [ -f "$D/idProduct" ]; then
    v=$(cat "$D/idVendor")
    p=$(cat "$D/idProduct")
    if [ "$v" = "$VID" ] && [ "$p" = "$PID" ]; then
      SYSDEV="$D"
      break
    fi
  fi
done

if [ -z "$SYSDEV" ]; then
  echo "Device $VIDPID not found"
  exit 1
fi

BUSID=$(basename "$SYSDEV")
echo "Found: $BUSID at $SYSDEV"

# Get driver
DRIVER=$(basename "$(readlink -f "$SYSDEV/driver" 2>/dev/null || echo '')")
if [ -z "$DRIVER" ]; then
  echo "No driver bound. Trying authorize toggle..."
  echo 0 | sudo tee "$SYSDEV/authorized" >/dev/null
  sleep 1
  echo 1 | sudo tee "$SYSDEV/authorized" >/dev/null
  echo "Authorization toggled"
else
  echo "Unbinding $DRIVER..."
  echo "$BUSID" | sudo tee "$SYSDEV/driver/unbind" >/dev/null
  sleep 2
  echo "Rebinding..."
  echo "$BUSID" | sudo tee "$SYSDEV/driver/bind" >/dev/null
  sleep 2
fi

echo "Reset complete. Checking device..."
lsusb -d "$VID:$PID" && echo "✓ Device visible" || echo "✗ Device not responding"
