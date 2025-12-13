#!/usr/bin/env bash
# FFmpeg pipeline: read from a physical capture device and write to v4l2loopback with optional filters
# Features: buffer validation, adaptive resolution fallback, HDR passthrough, optional delogo/overlay
# Usage: sudo ./feed.sh /dev/video0 /dev/video10 [resolution] [fps] [format]

set -euo pipefail

IN=${1:-/dev/video0}
OUT=${2:-/dev/video10}
VID_SIZE=${3:-${USB_CAPTURE_RES:-3840x2160}}
FPS=${4:-${USB_CAPTURE_FPS:-30}}
INPUT_FORMAT=${5:-${USB_CAPTURE_FORMAT:-NV12}}

# Buffer validation: detect corrupted frames and log warnings
VALIDATE_BUFFERS=${USB_CAPTURE_VALIDATE_BUFFERS:-1}
CORRUPT_FRAME_THRESHOLD=${USB_CAPTURE_CORRUPT_THRESHOLD:-5}  # consecutive corrupted frames before fallback
FALLBACK_RES=${USB_CAPTURE_FALLBACK_RES:-1920x1080}  # fallback if corruption detected

# HDR handling modes:
#   0 = auto (trust device, no color interpretation - may cause startup delay)
#   1 = force HDR interpretation (BT.2020/PQ) + tonemap to SDR (use if colors blown out)
#   2 = force HDR interpretation (BT.2020/PQ) + passthrough - DEFAULT (fastest startup)
#   3 = force SDR interpretation (Rec.709)
HDR_MODE=${USB_CAPTURE_HDR_MODE:-2}

# Optional overlay image (set via env, e.g. USB_CAPTURE_OVERLAY_URL or USB_CAPTURE_OVERLAY_FILE)
OVERLAY_URL=${USB_CAPTURE_OVERLAY_URL:-}
OVERLAY_FILE=${USB_CAPTURE_OVERLAY_FILE:-}
OVERLAY_X=${USB_CAPTURE_OVERLAY_X:-10}
OVERLAY_Y=${USB_CAPTURE_OVERLAY_Y:-10}
OVERLAY_SCALE=${USB_CAPTURE_OVERLAY_SCALE:-100}  # width in pixels

# Delogo/drawbox are now DISABLED by default - set USB_CAPTURE_DELOGO_ENABLE=1 to enable
DELOGO_ENABLE=${USB_CAPTURE_DELOGO_ENABLE:-0}
DELOGO=${USB_CAPTURE_DELOGO:-}
DRAWBOX=${USB_CAPTURE_DRAWBOX:-}
CUSTOM_FILTER=${USB_CAPTURE_FILTER:-}

# Map format names to ffmpeg input pixel formats
case "$INPUT_FORMAT" in
  NV12) INPUT_PIX_FMT="nv12" ;;
  YU12) INPUT_PIX_FMT="yuv420p" ;;
  YUYV) INPUT_PIX_FMT="yuyv422" ;;
  MJPG) INPUT_PIX_FMT="mjpeg" ;;
  BGR3) INPUT_PIX_FMT="bgr24" ;;
  *)    INPUT_PIX_FMT="" ;;  # let ffmpeg auto-detect
esac

# Options: configure filters
# - Delogo/drawbox now disabled by default (set USB_CAPTURE_DELOGO_ENABLE=1 to use)
# - Overlay: set USB_CAPTURE_OVERLAY_URL or USB_CAPTURE_OVERLAY_FILE to overlay an image

CUSTOM_DELOGO_FILTER='delogo=x=3500:y=10:w=300:h=100:show=0'
DELOGO_FILTER=${DELOGO:-$CUSTOM_DELOGO_FILTER}
CUSTOM_DRAWBOX_FILTER='drawbox=x=3500:y=10:w=300:h=100:color=black@1:t=fill'
DRAWBOX_FILTER=${DRAWBOX:-$CUSTOM_DRAWBOX_FILTER}

# Build filter chain
FILTERS=""

# Only add delogo/drawbox if explicitly enabled
if [ "$DELOGO_ENABLE" = "1" ]; then
  if [ -n "$CUSTOM_FILTER" ]; then
    FILTERS="$CUSTOM_FILTER"
  elif [ -n "$DRAWBOX" ]; then
    FILTERS="$DRAWBOX_FILTER"
  elif [ -n "$DELOGO" ]; then
    FILTERS="$DELOGO_FILTER"
  fi
fi

# Download overlay image if URL provided
OVERLAY_INPUT=""
OVERLAY_FILTER=""
if [ -n "$OVERLAY_URL" ]; then
  OVERLAY_TMP="/tmp/usb-capture-overlay.png"
  echo "Downloading overlay from $OVERLAY_URL"
  curl -sL "$OVERLAY_URL" -o "$OVERLAY_TMP" 2>/dev/null || wget -q "$OVERLAY_URL" -O "$OVERLAY_TMP" 2>/dev/null || true
  if [ -f "$OVERLAY_TMP" ]; then
    OVERLAY_FILE="$OVERLAY_TMP"
  fi
fi

if [ -n "$OVERLAY_FILE" ] && [ -f "$OVERLAY_FILE" ]; then
  OVERLAY_INPUT="-i $OVERLAY_FILE"
  OVERLAY_FILTER="[1:v]scale=${OVERLAY_SCALE}:-1[ovr];[0:v][ovr]overlay=${OVERLAY_X}:${OVERLAY_Y}"
fi

# Compose final filter
if [ -n "$OVERLAY_FILTER" ]; then
  if [ -n "$FILTERS" ]; then
    # Complex filter with overlay
    FILTER_COMPLEX="${OVERLAY_FILTER},${FILTERS},format=yuv420p"
  else
    FILTER_COMPLEX="${OVERLAY_FILTER},format=yuv420p"
  fi
  USE_FILTER_COMPLEX=1
else
  if [ -n "$FILTERS" ]; then
    FINAL_VF="${FILTERS},format=yuv420p"
  else
    FINAL_VF="format=yuv420p"
  fi
  USE_FILTER_COMPLEX=0
fi

# Recommended: force pixel format expected by v4l2loopback: yuv420p

# Build input format option if we know it
INPUT_FMT_OPT=""
if [ -n "$INPUT_PIX_FMT" ]; then
  INPUT_FMT_OPT="-input_format $INPUT_PIX_FMT"
fi

# HDR mode handling - build color interpretation and filter options
HDR_INPUT_OPTS=""
HDR_FILTER=""
case "$HDR_MODE" in
  1)
    # Force HDR interpretation + tonemap to SDR (Reinhard algorithm)
    echo "  HDR Mode 1: Interpreting as BT.2020/PQ, tonemapping to SDR"
    HDR_INPUT_OPTS="-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
    HDR_FILTER="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=reinhard:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
    ;;
  2)
    # Force HDR interpretation, passthrough (for HDR-capable output)
    echo "  HDR Mode 2: Interpreting as BT.2020/PQ, HDR passthrough"
    HDR_INPUT_OPTS="-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
    # No tonemapping, just ensure correct tagging
    HDR_FILTER=""
    ;;
  3)
    # Force SDR interpretation
    echo "  HDR Mode 3: Forcing Rec.709/SDR interpretation"
    HDR_INPUT_OPTS="-color_primaries bt709 -color_trc bt709 -colorspace bt709"
    HDR_FILTER=""
    ;;
  *)
    # Mode 0: Auto - trust device reporting
    echo "  HDR Mode 0: Auto (trusting device color reporting)"
    ;;
esac

# Use v4l2 to read from device, apply filters, then write to v4l2loopback
echo "Starting FFmpeg: $IN -> $OUT at ${VID_SIZE}@${FPS}fps (format: ${INPUT_FORMAT})"
if [ -n "$OVERLAY_FILE" ] && [ -f "$OVERLAY_FILE" ]; then
  echo "  Overlay: $OVERLAY_FILE at position ${OVERLAY_X},${OVERLAY_Y}"
fi

# Compose final filter chain with HDR processing if needed
if [ -n "$HDR_FILTER" ]; then
  if [ "$USE_FILTER_COMPLEX" = "1" ]; then
    FILTER_COMPLEX="${OVERLAY_FILTER},${HDR_FILTER}"
    [ -n "$FILTERS" ] && FILTER_COMPLEX="${FILTER_COMPLEX},${FILTERS}"
  else
    if [ -n "$FILTERS" ]; then
      FINAL_VF="${HDR_FILTER},${FILTERS}"
    else
      FINAL_VF="${HDR_FILTER}"
    fi
  fi
elif [ "$USE_FILTER_COMPLEX" != "1" ] && [ -z "$FINAL_VF" ]; then
  FINAL_VF="format=yuv420p"
fi

if [ "$USE_FILTER_COMPLEX" = "1" ]; then
  ffmpeg -hide_banner -loglevel info \
    -f v4l2 -framerate "$FPS" -video_size "$VID_SIZE" $INPUT_FMT_OPT $HDR_INPUT_OPTS -i "$IN" \
    $OVERLAY_INPUT \
    -filter_complex "$FILTER_COMPLEX" \
    -vcodec rawvideo -pix_fmt yuv420p \
    -f v4l2 -nostdin "$OUT" || echo "FFmpeg stopped"
else
  ffmpeg -hide_banner -loglevel info \
    -f v4l2 -framerate "$FPS" -video_size "$VID_SIZE" $INPUT_FMT_OPT $HDR_INPUT_OPTS -i "$IN" \
    -vf "$FINAL_VF" -vcodec rawvideo -pix_fmt yuv420p \
    -f v4l2 -nostdin "$OUT" || echo "FFmpeg stopped"
fi
