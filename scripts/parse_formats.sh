#!/usr/bin/env bash
# Parse v4l2-ctl --list-formats-ext output and generate v4l2loopback configuration
# Usage: ./parse_formats.sh /dev/video0
# Outputs environment variables for loopback configuration

set -euo pipefail
DEV=${1:-/dev/video0}

if [ ! -c "$DEV" ]; then
  echo "Device $DEV not found" >&2
  exit 1
fi

# Get formats
FORMATS_RAW=$(v4l2-ctl -d "$DEV" --list-formats-ext 2>/dev/null)

# Parse to find the highest resolution and its max fps for NV12/YU12 (4:2:0 formats preferred for 4K)
# Also collect all unique resolutions and framerates

declare -A RESOLUTIONS
declare -A MAX_FPS
BEST_RES=""
BEST_FPS=0
BEST_FORMAT=""

current_format=""
current_res=""

while IFS= read -r line; do
  # Match format line like "[1]: 'NV12' (Y/UV 4:2:0)"
  if [[ "$line" =~ \[([0-9]+)\]:\ \'([A-Z0-9]+)\' ]]; then
    current_format="${BASH_REMATCH[2]}"
  fi
  
  # Match resolution line like "Size: Discrete 3840x2160"
  if [[ "$line" =~ Size:\ Discrete\ ([0-9]+)x([0-9]+) ]]; then
    current_res="${BASH_REMATCH[1]}x${BASH_REMATCH[2]}"
    RESOLUTIONS["$current_res"]=1
  fi
  
  # Match framerate line like "Interval: Discrete 0.033s (30.000 fps)"
  if [[ "$line" =~ Interval:\ Discrete\ [0-9.]+s\ \(([0-9.]+)\ fps\) ]]; then
    fps="${BASH_REMATCH[1]}"
    fps_int=${fps%.*}  # truncate to integer
    
    # Track max fps per resolution
    key="${current_res}"
    if [ -z "${MAX_FPS[$key]:-}" ] || [ "$fps_int" -gt "${MAX_FPS[$key]}" ]; then
      MAX_FPS["$key"]=$fps_int
    fi
    
    # Find best resolution (prefer 4K, then highest res with good fps)
    width=${current_res%x*}
    height=${current_res#*x}
    pixels=$((width * height))
    
    # Prefer NV12/YU12/YUYV for 4K uncompressed; include MJPG so 4K@60fps is reachable
    if [[ "$current_format" =~ ^(NV12|YU12|YUYV|MJPG)$ ]]; then
      if [ "$current_res" == "3840x2160" ] && [ "$fps_int" -ge 25 ]; then
        if [ -z "$BEST_RES" ] || [ "$fps_int" -gt "$BEST_FPS" ] || [ "$BEST_RES" != "3840x2160" ]; then
          BEST_RES="$current_res"
          BEST_FPS=$fps_int
          BEST_FORMAT="$current_format"
        fi
      elif [ -z "$BEST_RES" ] && [ "$fps_int" -ge 25 ]; then
        BEST_RES="$current_res"
        BEST_FPS=$fps_int
        BEST_FORMAT="$current_format"
      fi
    fi
  fi
done <<< "$FORMATS_RAW"

# Fallback if nothing found
if [ -z "$BEST_RES" ]; then
  BEST_RES="1920x1080"
  BEST_FPS=30
  BEST_FORMAT="YUYV"
fi

# Generate all resolutions with their max fps as a comma-separated list for reference
ALL_RES=""
for res in "${!RESOLUTIONS[@]}"; do
  fps=${MAX_FPS[$res]:-30}
  ALL_RES="${ALL_RES}${res}@${fps},"
done
ALL_RES=${ALL_RES%,}  # trim trailing comma

# Output as sourceable environment variables
cat <<EOF
# Auto-detected formats from $DEV
USB_CAPTURE_BEST_RES="$BEST_RES"
USB_CAPTURE_BEST_FPS="$BEST_FPS"
USB_CAPTURE_BEST_FORMAT="$BEST_FORMAT"
USB_CAPTURE_ALL_RES="$ALL_RES"
USB_CAPTURE_WIDTH="${BEST_RES%x*}"
USB_CAPTURE_HEIGHT="${BEST_RES#*x}"
EOF
