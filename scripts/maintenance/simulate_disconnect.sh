#!/usr/bin/env bash
# toggle authorized on the usb device; test script only
# Usage: sudo ./simulate_disconnect.sh VID:PID
MAINTENANCE_DESC="Toggle device authorized state (test)"
MAINTENANCE_ARGS="vidpid"

set -euo pipefail
if [ $# -ne 1 ]; then
  echo "Usage: $0 VID:PID"
  exit 2
fi
VID=$(echo "$1" | cut -d: -f1)
PID=$(echo "$1" | cut -d: -f2)

device_sys=$(ls -d /sys/bus/usb/devices/* 2>/dev/null | while read D; do if [ -f "$D/idVendor" -a -f "$D/idProduct" ]; then v=$(cat $D/idVendor); p=$(cat $D/idProduct); if [[ "$v" == "$VID" && "$p" == "$PID" ]]; then echo "$D"; fi; fi; done | head -n1)
if [ -z "$device_sys" ]; then
  echo "Device not found"
  exit 3
fi

author="$(cat "$device_sys/authorized")"
if [ "$author" == "1" ]; then
  echo "Simulating disconnect by setting authorized=0"
  echo 0 > "$device_sys/authorized"
else
  echo "Simulating connect by setting authorized=1"
  echo 1 > "$device_sys/authorized"
fi
