#!/usr/bin/env bash
# FFmpeg pipeline: read from a physical capture device and write to v4l2loopback with optional filters
# Features: buffer validation, HDR metadata preservation, optional delogo/overlay
# Usage: ./feed.sh /dev/usb-video-capture1 /dev/video10 [resolution] [fps] [format]
#
# CRITICAL: HDR passthrough requires keeping NV12 format end-to-end.
# Previous versions forced yuv420p output which stripped all HDR metadata.
# v4l2loopback receives NV12 + V4L2 colorspace controls to signal HDR to readers.

set -euo pipefail

IN=${1:-/dev/usb-video-capture1}
OUT=${2:-/dev/video10}
VID_SIZE=${3:-${USB_CAPTURE_RES:-3840x2160}}
FPS=${4:-${USB_CAPTURE_FPS:-30}}
INPUT_FORMAT=${5:-${USB_CAPTURE_FORMAT:-NV12}}

# HDR handling modes:
#   0 = auto (trust device, no colour interpretation)
#   1 = force HDR interpretation (BT.2020/PQ) + tonemap to SDR (use if colours blown out)
#   2 = force HDR interpretation (BT.2020/PQ) + passthrough NV12 - DEFAULT
#   3 = force SDR interpretation (Rec.709)
HDR_MODE=${USB_CAPTURE_HDR_MODE:-2}

# Output pixel format - NV12 preserves HDR metadata, yuv420p strips it
# Only change to yuv420p if your loopback consumer cannot handle NV12
OUTPUT_PIX_FMT=${USB_CAPTURE_OUTPUT_PIX_FMT:-nv12}

# LD_PRELOAD shim: patches VIDIOC_S_FMT colorspace to BT.2020/PQ when FFmpeg opens
# the loopback output device. This is the only way to get the correct colorspace
# into v4l2loopback — FFmpeg's v4l2 muxer always writes colorspace=0 (sRGB).
_SHIM_SO="$(cd "$(dirname "$0")/.." && pwd)/src/v4l2-hdr-shim.so"
FFMPEG_LD_PRELOAD=""
if [ -f "$_SHIM_SO" ]; then
  FFMPEG_LD_PRELOAD="$_SHIM_SO"
else
  echo "  WARN: v4l2-hdr-shim.so not found at $_SHIM_SO — loopback colorspace will be sRGB"
  echo "        Build with: make -C $(dirname $_SHIM_SO) shim"
fi

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

# Build input format option
INPUT_FMT_OPT=""
if [ -n "$INPUT_PIX_FMT" ]; then
  INPUT_FMT_OPT="-input_format $INPUT_PIX_FMT"
fi

# HDR mode: set input colour metadata and output pixel format
HDR_INPUT_OPTS=""
HDR_OUTPUT_OPTS=""
HDR_FILTER=""
case "$HDR_MODE" in
  1)
    # HDR input + tonemap to SDR, yuv420p out
    echo "  HDR Mode 1: BT.2020/PQ input, tonemapping to SDR yuv420p"
    HDR_INPUT_OPTS="-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
    HDR_FILTER="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=reinhard:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
    OUTPUT_PIX_FMT="yuv420p"
    ;;
  2)
    # HDR passthrough: keep NV12, propagate colour metadata to output
    # This is what allows OBS/downstream to classify the stream as HDR
    echo "  HDR Mode 2: BT.2020/PQ passthrough, NV12 preserved to loopback"
    HDR_INPUT_OPTS="-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
    HDR_OUTPUT_OPTS="-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv"
    OUTPUT_PIX_FMT="nv12"
    HDR_FILTER=""
    ;;
  3)
    # Force SDR
    echo "  HDR Mode 3: Rec.709/SDR, yuv420p out"
    HDR_INPUT_OPTS="-color_primaries bt709 -color_trc bt709 -colorspace bt709"
    OUTPUT_PIX_FMT="yuv420p"
    HDR_FILTER=""
    ;;
  *)
    # Mode 0: Auto
    echo "  HDR Mode 0: Auto (trusting device colour reporting, NV12 preserved)"
    OUTPUT_PIX_FMT="nv12"
    ;;
esac

echo "Starting FFmpeg: $IN -> $OUT at ${VID_SIZE}@${FPS}fps (format: ${INPUT_FORMAT}, out: ${OUTPUT_PIX_FMT})"

# Build filter string
FINAL_VF=""
if [ -n "$HDR_FILTER" ] && [ -n "$FILTERS" ]; then
  FINAL_VF="${HDR_FILTER},${FILTERS}"
elif [ -n "$HDR_FILTER" ]; then
  FINAL_VF="${HDR_FILTER}"
elif [ -n "$FILTERS" ]; then
  FINAL_VF="${FILTERS}"
fi

# Run FFmpeg under LD_PRELOAD shim so VIDIOC_S_FMT on the loopback output device
# gets BT.2020/PQ colorspace rather than the sRGB default the v4l2 muxer writes.
# V4L2_HDR_SHIM_DEVICE restricts patching to the loopback output only.
if [ -n "$OVERLAY_FILTER" ]; then
  # Complex filter path (with overlay)
  FILTER_COMPLEX="${OVERLAY_FILTER}"
  [ -n "$FINAL_VF" ] && FILTER_COMPLEX="${FILTER_COMPLEX},${FINAL_VF}"
  LD_PRELOAD="${FFMPEG_LD_PRELOAD}" V4L2_HDR_SHIM_DEVICE="$OUT" \
  ffmpeg -hide_banner -loglevel info \
    -thread_queue_size 16 -rtbufsize 256M \
    -f v4l2 -framerate "$FPS" -video_size "$VID_SIZE" $INPUT_FMT_OPT $HDR_INPUT_OPTS -i "$IN" \
    $OVERLAY_INPUT \
    -filter_complex "$FILTER_COMPLEX" \
    -vcodec rawvideo -pix_fmt "$OUTPUT_PIX_FMT" $HDR_OUTPUT_OPTS \
    -f v4l2 -nostdin "$OUT" || echo "FFmpeg stopped"
elif [ -n "$FINAL_VF" ]; then
  LD_PRELOAD="${FFMPEG_LD_PRELOAD}" V4L2_HDR_SHIM_DEVICE="$OUT" \
  ffmpeg -hide_banner -loglevel info \
    -thread_queue_size 16 -rtbufsize 256M \
    -f v4l2 -framerate "$FPS" -video_size "$VID_SIZE" $INPUT_FMT_OPT $HDR_INPUT_OPTS -i "$IN" \
    -vf "$FINAL_VF" \
    -vcodec rawvideo -pix_fmt "$OUTPUT_PIX_FMT" $HDR_OUTPUT_OPTS \
    -f v4l2 -nostdin "$OUT" || echo "FFmpeg stopped"
else
  # Clean passthrough: no filter, just relay with colour metadata
  LD_PRELOAD="${FFMPEG_LD_PRELOAD}" V4L2_HDR_SHIM_DEVICE="$OUT" \
  ffmpeg -hide_banner -loglevel info \
    -thread_queue_size 16 -rtbufsize 256M \
    -f v4l2 -framerate "$FPS" -video_size "$VID_SIZE" $INPUT_FMT_OPT $HDR_INPUT_OPTS -i "$IN" \
    -vcodec rawvideo -pix_fmt "$OUTPUT_PIX_FMT" $HDR_OUTPUT_OPTS \
    -f v4l2 -nostdin "$OUT" || echo "FFmpeg stopped"
fi
