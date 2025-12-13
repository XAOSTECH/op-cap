#!/usr/bin/env bash
# Try to disable on-screen logos/OSD using standard UVC controls (if supported)
# Usage: sudo ./disable_overlay.sh /dev/video0
MAINTENANCE_DESC="Remove on-screen logos/OSD from capture"
MAINTENANCE_ARGS="device_path"

set -euo pipefail

DEV=${1:-/dev/video0}

if [ ! -c "$DEV" ]; then
  echo "$DEV not found or not a character device"; exit 2
fi

# show controls
if [ -x "$(command -v v4l2-ctl)" ]; then
  echo "v4l2 controls for $DEV:"; v4l2-ctl -d $DEV --list-ctrls; echo
else
  echo "v4l2-ctl not installed; install v4l-utils"
fi

# Some devices expose 'applets' or 'overlay' controls; try a few likely ones
if command -v uvcdynctrl >/dev/null 2>&1; then
  for ctrl in "Processing" "Overlay" "OSD" "Logo" "Privacy"; do
    echo "Trying uvcdynctrl for $ctrl"
    uvcdynctrl -d $DEV -s "$ctrl" 0 2>/dev/null || true
  done
fi

# try some v4l2 known controls
v4l2_known_ctrls=("exposure_auto" "gain" "white_balance_temperature_auto" "power_line_frequency" "brightness" "sharpness" "contrast" "saturation")
for c in "${v4l2_known_ctrls[@]}"; do
  echo "Checking and printing $c"
  v4l2-ctl -d $DEV --get-ctrl=$c 2>/dev/null || true
done

# Finally, advise crop or delogo via FFmpeg if control not present
cat <<'EOF'
If the device doesn't expose a control to remove the OSD, use the FFmpeg delogo/crop filter.
Example:
  ffmpeg -f v4l2 -i /dev/video0 -vf "delogo=x=3500:y=10:w=300:h=100:show=0,format=yuv420p" -f v4l2 /dev/video2
Or: crop to remove the logo region:
  ffmpeg -f v4l2 -i /dev/video0 -vf "crop=3840:2100:0:0,format=yuv420p" -f v4l2 /dev/video2
EOF
