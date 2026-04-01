#!/usr/bin/env bash
set -euo pipefail
BASEDIR=$(cd "$(dirname "$0")/.." && pwd)

echo "Building usbreset tool"
if command -v gcc >/dev/null 2>&1; then
  gcc "$BASEDIR/scripts/usbreset.c" -o "$BASEDIR/scripts/usbreset" || { echo "gcc failed"; exit 1; }
  chmod +x "$BASEDIR/scripts/usbreset"
  chmod +x "$BASEDIR/scripts/"*.sh || true
  chmod +x "$BASEDIR/ffmpeg/"*.sh || true
else
  echo "GCC not found. Install build-essential"; exit 1
fi

# Validation checks: ensure required commands exist
echo "Checking for required dependencies..."
MISSING=()
for cmd in ffmpeg v4l2-ctl modprobe systemctl udevadm lsusb journalctl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING+=("$cmd")
  fi
done

# Suggest installing helpful utilities
echo "Checking optional utilities: 'slop' for delogo pick and 'uhubctl' for hub power control"
for opt in slop uhubctl uvcdynctrl; do
  if ! command -v $opt >/dev/null 2>&1; then
    echo "Optional: $opt not installed. Install if you want $opt-related features."
  fi
done

# Try loading v4l2loopback to ensure module present
if command -v modprobe >/dev/null 2>&1; then
  echo "Attempting to load v4l2loopback module (will be loaded by systemd unit if module available)"
  sudo modprobe v4l2loopback || true
  if lsmod | grep -q v4l2loopback; then
    echo "v4l2loopback module loaded"
  else
    echo "v4l2loopback module not loaded — please install v4l2loopback-dkms if you want loopback outputs"
  fi
fi
if [ ${#MISSING[@]} -ne 0 ]; then
  echo "Warning: Missing commands: ${MISSING[*]}."
  echo "Please install the missing packages (e.g., sudo apt install ffmpeg v4l-utils v4l2loopback-dkms usbutils)"
fi

# Interactive selection: detect /dev/video* and ask the user which to use
echo "Detecting available video devices..."
mapfile -t VIDEO_DEVICES < <(ls -1 /dev/video* 2>/dev/null || true)
if [ ${#VIDEO_DEVICES[@]} -eq 0 ]; then
  echo "No video devices found. Please plug in your capture device and try again."
  exit 1
fi
if [ ${#VIDEO_DEVICES[@]} -eq 1 ]; then
  CHOSEN=${VIDEO_DEVICES[0]}
else
  echo "Multiple video devices found, please select one by number:"
  for i in "${!VIDEO_DEVICES[@]}"; do
    echo "[$i] ${VIDEO_DEVICES[$i]}"
  done
  while true; do
    read -rp "Choice: " CHOICE
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 0 ] && [ "$CHOICE" -lt "${#VIDEO_DEVICES[@]}" ]; then
      CHOSEN=${VIDEO_DEVICES[$CHOICE]}
      break
    fi
    echo "Invalid choice"
  done
fi

echo "Using device: $CHOSEN"

UEV_PROPS=$(udevadm info -q property -n "$CHOSEN")
ID_VENDOR_ID=$(echo "$UEV_PROPS" | awk -F= '/ID_VENDOR_ID=/{print $2; exit}')
ID_MODEL_ID=$(echo "$UEV_PROPS" | awk -F= '/ID_MODEL_ID=/{print $2; exit}')
ID_VENDOR=$(echo "$UEV_PROPS" | awk -F= '/ID_VENDOR=/{print $2; exit}')
ID_MODEL=$(echo "$UEV_PROPS" | awk -F= '/ID_MODEL=/{print $2; exit}')
VIDPID="${ID_VENDOR_ID}:${ID_MODEL_ID}"

# Parse device formats to auto-detect best resolution/fps
echo "Detecting device capabilities..."
if [ -x "$BASEDIR/scripts/parse_formats.sh" ]; then
  FORMAT_INFO=$("$BASEDIR/scripts/parse_formats.sh" "$CHOSEN" 2>/dev/null || true)
  if [ -n "$FORMAT_INFO" ]; then
    eval "$FORMAT_INFO"
    echo "Detected: ${USB_CAPTURE_BEST_RES:-1920x1080} @ ${USB_CAPTURE_BEST_FPS:-30}fps (${USB_CAPTURE_BEST_FORMAT:-YUYV})"
  else
    USB_CAPTURE_BEST_RES="1920x1080"
    USB_CAPTURE_BEST_FPS="30"
    USB_CAPTURE_WIDTH="1920"
    USB_CAPTURE_HEIGHT="1080"
    echo "Could not detect formats, using defaults: 1920x1080@30fps"
  fi
else
  USB_CAPTURE_BEST_RES="1920x1080"
  USB_CAPTURE_BEST_FPS="30"
  USB_CAPTURE_WIDTH="1920"
  USB_CAPTURE_HEIGHT="1080"
  echo "Format parser not found, using defaults: 1920x1080@30fps"
fi

# Try to find a persistent path (/dev/v4l/by-id or by-path)
PERSISTENT_PATH=$CHOSEN
if [ -d /dev/v4l/by-id ]; then
  BY_ID=$(ls -1 /dev/v4l/by-id/* 2>/dev/null | grep -i "${ID_VENDOR:-}\|${ID_MODEL:-}" | head -n1 || true)
  if [ -n "$BY_ID" ]; then
    PERSISTENT_PATH=$BY_ID
  fi
fi
if [ -d /dev/v4l/by-path ] && [ "$PERSISTENT_PATH" == "$CHOSEN" ]; then
  BY_PATH=$(readlink -f /dev/v4l/by-path/* 2>/dev/null | grep -F "$CHOSEN" -m1 | head -n1 || true)
  if [ -n "$BY_PATH" ]; then
    PERSISTENT_PATH=$BY_PATH
  fi
fi

echo "Chosen persistent path: $PERSISTENT_PATH"

# Optional: configure overlay
OVERLAY_URL=""
OVERLAY_X="10"
OVERLAY_Y="10"
OVERLAY_SCALE="500"
read -rp "Add an overlay image? (URL or local path, leave empty to skip): " OVERLAY_INPUT
if [ -n "$OVERLAY_INPUT" ]; then
  if [[ "$OVERLAY_INPUT" =~ ^https?:// ]]; then
    OVERLAY_URL="$OVERLAY_INPUT"
    echo "Overlay URL set: $OVERLAY_URL"
  elif [ -f "$OVERLAY_INPUT" ]; then
    OVERLAY_FILE="$OVERLAY_INPUT"
    echo "Overlay file set: $OVERLAY_FILE"
  else
    echo "Warning: '$OVERLAY_INPUT' is not a valid URL or existing file. Skipping overlay."
    OVERLAY_INPUT=""
  fi
  if [ -n "$OVERLAY_INPUT" ]; then
    read -rp "Overlay X position [10]: " inp; OVERLAY_X="${inp:-10}"
    read -rp "Overlay Y position [10]: " inp; OVERLAY_Y="${inp:-10}"
    read -rp "Overlay width in pixels [100]: " inp; OVERLAY_SCALE="${inp:-100}"
  fi
fi

ENVFILE=/etc/default/usb-capture
sudo tee "$ENVFILE" >/dev/null <<EOL
# USB capture environment file
USB_CAPTURE_VIDEO="$PERSISTENT_PATH"
USB_CAPTURE_VIDPID="$VIDPID"
USB_CAPTURE_VENDOR="$ID_VENDOR"
USB_CAPTURE_MODEL="$ID_MODEL"
USB_CAPTURE_RES="${USB_CAPTURE_BEST_RES:-1920x1080}"
USB_CAPTURE_FPS="${USB_CAPTURE_BEST_FPS:-30}"
USB_CAPTURE_WIDTH="${USB_CAPTURE_WIDTH:-1920}"
USB_CAPTURE_HEIGHT="${USB_CAPTURE_HEIGHT:-1080}"
USB_CAPTURE_FORMAT="${USB_CAPTURE_BEST_FORMAT:-YUYV}"
# Overlay settings (leave empty to disable)
USB_CAPTURE_OVERLAY_URL="${OVERLAY_URL:-}"
USB_CAPTURE_OVERLAY_FILE="${OVERLAY_FILE:-}"
USB_CAPTURE_OVERLAY_X="${OVERLAY_X}"
USB_CAPTURE_OVERLAY_Y="${OVERLAY_Y}"
USB_CAPTURE_OVERLAY_SCALE="${OVERLAY_SCALE}"
EOL
sudo chmod 644 "$ENVFILE"

# Validate the chosen persistent path exists and is a character device or symlink
if [ ! -e "$PERSISTENT_PATH" ]; then
  echo "Warning: persistent path $PERSISTENT_PATH does not exist after writing env file. If the device moved ports, re-run this installer after plugging the device in."
fi

# Copy udev rule and ensure autosuspend is off
# Generate device-specific udev rule for performance
echo "Generating device-specific udev rule for $VIDPID"
sudo tee /etc/udev/rules.d/99-usb-capture.rules >/dev/null <<UDEVRULE
# USB capture device performance optimizations for $ID_VENDOR $ID_MODEL
# Disable autosuspend
ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="$ID_VENDOR_ID", ATTR{idProduct}=="$ID_MODEL_ID", ATTR{power/control}="on"
ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="$ID_VENDOR_ID", ATTR{idProduct}=="$ID_MODEL_ID", ATTR{power/autosuspend_delay_ms}="-1"
# Symlink for easier access
ACTION=="add|change", SUBSYSTEM=="video4linux", ATTRS{idVendor}=="$ID_VENDOR_ID", ATTRS{idProduct}=="$ID_MODEL_ID", SYMLINK+="usb-capture0"
UDEVRULE
sudo udevadm control --reload-rules || true
sudo udevadm trigger || true

# Run device optimisation
if [ -x "$BASEDIR/scripts/optimise_device.sh" ]; then
  echo "Running device optimizations..."
  sudo "$BASEDIR/scripts/optimise_device.sh" "$VIDPID" || true
fi

# Install systemd services
echo "Installing systemd unit files (generated from install script)"
FF_SCRIPT="$BASEDIR/ffmpeg/feed.sh"
MON_SCRIPT="$BASEDIR/scripts/auto_reconnect.sh"

[ -d /etc/systemd/system ] || sudo mkdir -p /etc/systemd/system
sudo tee /etc/systemd/system/usb-capture-ffmpeg.service >/dev/null <<SVC_FFMPEG
[Unit]
Description=USB capture ffmpeg feed to v4l2loopback
After=multi-user.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/usb-capture
ExecStartPre=-/sbin/modprobe -r v4l2loopback
ExecStartPre=-/bin/sleep 1
ExecStartPre=-/sbin/modprobe v4l2loopback video_nr=10 card_label="USB_Capture_Loop" exclusive_caps=1
ExecStart=/bin/bash -c '$FF_SCRIPT \${USB_CAPTURE_VIDEO} /dev/video10 \${USB_CAPTURE_RES:-3840x2160} \${USB_CAPTURE_FPS:-30}'
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC_FFMPEG

sudo tee /etc/systemd/system/usb-capture-monitor.service >/dev/null <<SVC_MON
[Unit]
Description=USB capture monitor & auto reconnect
After=network.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/usb-capture
ExecStart=/bin/bash -c '$MON_SCRIPT --vidpid \$USB_CAPTURE_VIDPID --device \$USB_CAPTURE_VIDEO --ffmpeg-service usb-capture-ffmpeg.service'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC_MON

sudo systemctl daemon-reload
sudo systemctl enable --now usb-capture-ffmpeg.service usb-capture-monitor.service || true

# Ensure systemd units read our /etc/default/usb-capture env file
if ! sudo grep -q "EnvironmentFile=-/etc/default/usb-capture" /etc/systemd/system/usb-capture-ffmpeg.service 2>/dev/null; then
  sudo sed -i '/^\[Service\]/a EnvironmentFile=-/etc/default/usb-capture' /etc/systemd/system/usb-capture-ffmpeg.service || true
fi
if ! sudo grep -q "EnvironmentFile=-/etc/default/usb-capture" /etc/systemd/system/usb-capture-monitor.service 2>/dev/null; then
  sudo sed -i '/^\[Service\]/a EnvironmentFile=-/etc/default/usb-capture' /etc/systemd/system/usb-capture-monitor.service || true
fi
sudo systemctl daemon-reload || true

# Install host launch aliases (sobs/cobs)
if [ -x "$BASEDIR/scripts/generate_obs_aliases.sh" ]; then
  echo "Installing OBS safety aliases (sobs, cobs)..."
  "$BASEDIR/scripts/generate_obs_aliases.sh" --basedir "$BASEDIR" || true
fi

echo "Install process finished. Check service status with: sudo systemctl status usb-capture-ffmpeg.service usb-capture-monitor.service"
echo "Shortcuts: sobs (safe OBS no-loopback/no-device), cobs (pick capture device + safe OBS)"
