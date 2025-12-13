#!/usr/bin/env bash
# Reset a USB device. Usage: sudo ./usb_reset.sh <bus> <devnum> or <device_path> or <VID:PID>
# Also supports hub control: --disable-hub <bus> or --enable-hub <bus> or --authorize <bus>
MAINTENANCE_DESC="Reset USB device via ioctl or driver rebind"
MAINTENANCE_ARGS="vidpid"

set -euo pipefail

# Authorize (enable) USB device that was kept unauthorized on boot
function authorize_device() {
  local bus="$1"
  local sysdev="/sys/bus/usb/devices/$bus"
  
  if [ ! -d "$sysdev" ]; then
    echo "Error: USB device '$bus' not found in sysfs"
    echo "Available USB devices:"
    ls -1 /sys/bus/usb/devices/ | grep -E '^[0-9]' | head -20
    return 1
  fi
  
  if [ ! -f "$sysdev/authorized" ]; then
    echo "Error: Device '$bus' does not support authorization control"
    return 1
  fi
  
  # Check current authorization state
  local auth
  auth=$(cat "$sysdev/authorized" 2>/dev/null || echo "unknown")
  
  if [ "$auth" = "1" ]; then
    echo "Device $bus is already authorized and initialized"
    return 0
  fi
  
  if [ "$auth" = "0" ]; then
    echo "Device $bus is currently unauthorized. Authorizing..."
    # Write 1 to authorized to enable the device
    echo 1 | sudo tee "$sysdev/authorized" >/dev/null 2>&1 || {
      echo "Error: Could not write to $sysdev/authorized"
      echo "Try: echo 1 | sudo tee $sysdev/authorized"
      return 1
    }
  fi
  
  echo "Device authorized. Waiting for initialization..."
  sleep 3
  
  # Check if device properly enumerated
  if [ -f "$sysdev/idVendor" ] && [ -f "$sysdev/idProduct" ]; then
    local vid
    local pid
    vid=$(cat "$sysdev/idVendor" 2>/dev/null || echo "????")
    pid=$(cat "$sysdev/idProduct" 2>/dev/null || echo "????")
    echo "Device initialized: $vid:$pid"
  else
    echo "Warning: Could not verify device initialization"
  fi
  
  return 0
}

# Disable USB hub by writing 0 to power/autosuspend_delay_ms and removing devices
function disable_hub() {
  local bus="$1"
  local sysdev="/sys/bus/usb/devices/$bus"
  
  if [ ! -d "$sysdev" ]; then
    echo "Error: USB device '$bus' not found in sysfs"
    echo "Available USB devices:"
    ls -1 /sys/bus/usb/devices/ | grep -E '^[0-9]' | head -20
    return 1
  fi
  
  echo "Disabling USB hub/device: $bus"
  
  # Remove all child devices first (unbind drivers)
  for child in "$sysdev"/*/; do
    if [ -d "$child" ]; then
      child_id=$(basename "$child")
      echo "  Detaching child device: $child_id"
      
      # Unbind driver if present
      if [ -L "$child/driver" ]; then
        echo -n "$child_id" | sudo tee "$child/driver/unbind" >/dev/null 2>&1 || true
      fi
      
      # Remove device
      echo 1 | sudo tee "$child/remove" >/dev/null 2>&1 || true
    fi
  done
  
  # Now disable parent hub
  echo 0 | sudo tee "$sysdev/power/autosuspend_delay_ms" >/dev/null 2>&1 || true
  echo "auto" | sudo tee "$sysdev/power/control" >/dev/null 2>&1 || true
  
  echo "Hub disabled. Device should disconnect."
  sleep 2
  
  return 0
}

# Enable USB hub by resetting autosuspend and rescanning
function enable_hub() {
  local bus="$1"
  local sysdev="/sys/bus/usb/devices/$bus"
  
  if [ ! -d "$sysdev" ]; then
    echo "Error: USB device '$bus' not found in sysfs"
    echo "Available USB devices:"
    ls -1 /sys/bus/usb/devices/ | grep -E '^[0-9]' | head -20
    return 1
  fi
  
  echo "Enabling USB hub/device: $bus"
  
  # Re-enable autosuspend
  echo 2000 | sudo tee "$sysdev/power/autosuspend_delay_ms" >/dev/null 2>&1 || true
  echo "on" | sudo tee "$sysdev/power/control" >/dev/null 2>&1 || true
  
  # Trigger rescan to re-enumerate devices
  echo 1 | sudo tee /sys/bus/usb/devices/usb1/rescan >/dev/null 2>&1 || true
  echo 1 | sudo tee /sys/bus/usb/devices/usb2/rescan >/dev/null 2>&1 || true
  
  echo "Hub enabled. Rescanning for devices..."
  sleep 2
  
  return 0
}

if [ $# -eq 0 ]; then
  echo "Usage: $0 <bus> <devnum> | /dev/bus/usb/BBB/DDD | vid:pid | --disable-hub <bus> | --enable-hub <bus> | --authorize <bus>"
  exit 2
fi

# Handle hub control and authorization options
if [[ "$1" =~ ^--(disable-hub|enable-hub|authorize)$ ]]; then
  if [ $# -lt 2 ]; then
    echo "Error: $1 requires a bus number"
    exit 1
  fi
  
  action="$1"
  bus="$2"
  
  case "$action" in
    --disable-hub)
      disable_hub "$bus"
      ;;
    --enable-hub)
      enable_hub "$bus"
      ;;
    --authorize)
      authorize_device "$bus"
      ;;
  esac
  
  exit 0
fi

function do_reset_path() {
  local path="$1"
  if [ -c "$path" ]; then
    # Look for usbreset in parent directory (scripts/), use absolute path
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local usbreset_bin="$script_dir/../usbreset"
    if [ -f "$usbreset_bin" ] && [ -x "$usbreset_bin" ]; then
      echo "Resetting USB device via ioctl ($path)..."
      "$usbreset_bin" "$path"
    else
      # Fallback: unbind and rebind driver
      echo "Attempting unbind/rebind fallback..."
      device_id=$(udevadm info -q path -n "$path" 2>/dev/null | sed 's,^/devices/,,') || true
      if [ -n "$device_id" ]; then
        busid=$(basename "$device_id")
        sysdev="/sys/devices/$device_id"
        if [ -d "$sysdev" ]; then
          driver=$(basename $(readlink -f "$sysdev/driver" 2>/dev/null || true) || true)
          if [ -n "$driver" ]; then
            echo "Unbinding $busid from driver..."
            echo -n "$busid" | sudo tee "$sysdev/driver/unbind" >/dev/null
            sleep 1
            echo "Rebinding $busid to driver..."
            echo -n "$busid" | sudo tee "$sysdev/driver/bind" >/dev/null
          fi
        fi
      fi
    fi
  else
    echo "$path is not a character device, can't usbreset"
    exit 1
  fi
}

if [[ "$1" =~ ^[0-9]{3}$ ]] && [[ "$2" =~ ^[0-9]{3}$ ]]; then
  BUS=$(printf "%03d" "$1")
  DEV=$(printf "%03d" "$2")
  device_node="/dev/bus/usb/$BUS/$DEV"
  do_reset_path "$device_node"
  exit 0
fi

if [[ "$1" =~ ^/dev/bus/usb/.+ ]]; then
  do_reset_path "$1"
  exit 0
fi

if [[ "$1" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
  VID=$(echo "$1" | cut -d: -f1)
  PID=$(echo "$1" | cut -d: -f2)
  busdev=""
  for D in /sys/bus/usb/devices/*-*; do
    if [[ -f "$D/idVendor" && -f "$D/idProduct" ]]; then
      v=$(cat "$D/idVendor")
      p=$(cat "$D/idProduct")
      if [[ "$v" == "$VID" && "$p" == "$PID" ]]; then
        busdev=$(basename "$D")
        break
      fi
    fi
  done
  if [ -z "$busdev" ]; then
    echo "No usb device found for $1"
    exit 2
  fi
  bus=$(cat /sys/bus/usb/devices/$busdev/busnum)
  dev=$(cat /sys/bus/usb/devices/$busdev/devnum)
  BUS=$(printf "%03d" "$bus")
  DEV=$(printf "%03d" "$dev")
  device_node="/dev/bus/usb/$BUS/$DEV"
  do_reset_path "$device_node"
  exit 0
fi

echo "Unknown argument format"
exit 3
