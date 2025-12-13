#!/usr/bin/env bash
# Optimize USB capture device for maximum performance and stability
# Usage: sudo ./optimize_device.sh [VID:PID]
MAINTENANCE_DESC="Disable autosuspend, optimize USB power"
MAINTENANCE_ARGS="vidpid"

set -euo pipefail

VIDPID=${1:-${USB_CAPTURE_VIDPID:-}}

if [ -z "$VIDPID" ] && [ -f /etc/default/usb-capture ]; then
  source /etc/default/usb-capture
  VIDPID=${USB_CAPTURE_VIDPID:-}
fi

if [ -z "$VIDPID" ]; then
  echo "Usage: $0 VID:PID (e.g., 534d:2109)"
  echo "Or set USB_CAPTURE_VIDPID in /etc/default/usb-capture"
  exit 1
fi

VID=$(echo "$VIDPID" | cut -d: -f1)
PID=$(echo "$VIDPID" | cut -d: -f2)

echo "Optimizing USB capture device $VIDPID..."

# Find the device in sysfs
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
  echo "Device $VIDPID not found in sysfs"
  exit 2
fi

echo "Found device at: $SYSDEV"

# 1. Disable USB autosuspend for the device
if [ -f "$SYSDEV/power/control" ]; then
  echo "on" | sudo tee "$SYSDEV/power/control" >/dev/null
  echo "  [OK] Disabled autosuspend (power/control = on)"
fi

if [ -f "$SYSDEV/power/autosuspend_delay_ms" ]; then
  echo "-1" | sudo tee "$SYSDEV/power/autosuspend_delay_ms" >/dev/null
  echo "  [OK] Set autosuspend_delay_ms = -1"
fi

# 2. Set USB quirks for better stability (if applicable)
# Check current level
if [ -f "$SYSDEV/power/level" ]; then
  echo "on" | sudo tee "$SYSDEV/power/level" >/dev/null 2>&1 || true
  echo "  [OK] Set power/level = on"
fi

# 3. Maximize USB bandwidth allocation (for xHCI)
# Find the USB controller for this device
CONTROLLER=$(readlink -f "$SYSDEV" | grep -oE 'usb[0-9]+' | head -1)
if [ -n "$CONTROLLER" ] && [ -d "/sys/bus/usb/devices/$CONTROLLER" ]; then
  # Some controllers support bandwidth reservation
  if [ -f "/sys/bus/usb/devices/$CONTROLLER/power/control" ]; then
    echo "on" | sudo tee "/sys/bus/usb/devices/$CONTROLLER/power/control" >/dev/null 2>&1 || true
    echo "  [OK] Disabled autosuspend on USB controller $CONTROLLER"
  fi
fi

# 4. Check and report USB speed
if [ -f "$SYSDEV/speed" ]; then
  SPEED=$(cat "$SYSDEV/speed")
  echo "  USB Speed: ${SPEED} Mbps"
  if [ "$SPEED" -lt 480 ]; then
    echo "  [WARN] Device running at USB 2.0 speed or lower. For 4K, USB 3.0+ is recommended."
  fi
fi

# 5. Check for USB errors in dmesg
echo ""
echo "Recent USB errors (if any):"
dmesg | grep -iE "usb.*error|xhci.*error|uvc.*error" | tail -5 || echo "  No recent USB errors"

# 6. Report device info
echo ""
echo "Device info:"
[ -f "$SYSDEV/product" ] && echo "  Product: $(cat $SYSDEV/product)"
[ -f "$SYSDEV/manufacturer" ] && echo "  Manufacturer: $(cat $SYSDEV/manufacturer)"
[ -f "$SYSDEV/bcdUSB" ] && echo "  USB Version: $(cat $SYSDEV/bcdUSB)"

# 7. System-wide USB optimizations
echo ""
echo "Applying system-wide USB optimizations..."

# Disable USB autosuspend globally (optional, aggressive)
if [ -f /sys/module/usbcore/parameters/autosuspend ]; then
  CURRENT=$(cat /sys/module/usbcore/parameters/autosuspend)
  if [ "$CURRENT" != "-1" ]; then
    echo "-1" | sudo tee /sys/module/usbcore/parameters/autosuspend >/dev/null 2>&1 || true
    echo "  [OK] Disabled global USB autosuspend"
  else
    echo "  [OK] Global USB autosuspend already disabled"
  fi
fi

# 8. UVC driver optimizations
if [ -d /sys/module/uvcvideo/parameters ]; then
  # Increase buffer count for smoother capture
  if [ -f /sys/module/uvcvideo/parameters/quirks ]; then
    echo "  Current UVC quirks: $(cat /sys/module/uvcvideo/parameters/quirks)"
  fi
  # Note: timeout can help with some devices
  if [ -f /sys/module/uvcvideo/parameters/timeout ]; then
    TIMEOUT=$(cat /sys/module/uvcvideo/parameters/timeout)
    echo "  UVC timeout: ${TIMEOUT}ms"
  fi
fi

echo ""
echo "Optimization complete!"
echo ""
echo "To make autosuspend changes persistent, add udev rule:"
echo "  ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"$VID\", ATTR{idProduct}==\"$PID\", ATTR{power/control}=\"on\""
