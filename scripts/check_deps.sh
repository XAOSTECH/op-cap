#!/usr/bin/env bash
# Check for dependencies
set -euo pipefail

check_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing: $cmd  → sudo apt install $pkg"
  else
    echo "OK: $cmd"
  fi
}

check_cmd gcc        build-essential
check_cmd ffmpeg     ffmpeg
check_cmd v4l2-ctl   v4l-utils
check_cmd modprobe   kmod
check_cmd systemctl  systemd
check_cmd lsusb      usbutils

# uvcdynctrl was removed from Ubuntu 22+; treat as optional
if command -v uvcdynctrl >/dev/null 2>&1; then
  echo "OK: uvcdynctrl (optional)"
else
  echo "OK (absent): uvcdynctrl is optional and no longer shipped on Ubuntu 22+"
fi

echo "Check kernel module: v4l2loopback"
if lsmod | grep -q v4l2loopback; then
  echo "v4l2loopback loaded"
else
  KERNEL=$(uname -r)
  echo "v4l2loopback not loaded (kernel: $KERNEL)"
  if dpkg -l v4l2loopback-dkms &>/dev/null 2>&1; then
    echo "  v4l2loopback-dkms installed; rebuild: sudo dkms install v4l2loopback -k $KERNEL"
  else
    echo "  Install: sudo apt install v4l2loopback-dkms linux-headers-$KERNEL"
  fi
fi

echo "Check drivers for video devices:"
for d in /dev/video*; do
  if [ -e "$d" ]; then
    echo "Device: $d"
    udevadm info -q property -n "$d" | grep -E 'ID_VENDOR|ID_MODEL|ID_PATH|ID_USB' || true
  fi
done
