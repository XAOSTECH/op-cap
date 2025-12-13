#!/usr/bin/env bash
# Validate USB capture device for buffer corruption issues
# Tests raw capture at different resolutions and reports corruption rate
# Usage: sudo ./validate_capture.sh /dev/video0 [resolution] [duration_secs]

set -euo pipefail

DEV=${1:-/dev/video0}
TEST_RES=${2:-3840x2160}
TEST_DURATION=${3:-5}

if [ ! -c "$DEV" ]; then
  echo "ERROR: $DEV is not a valid video device"
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ERROR: ffmpeg not found. Install ffmpeg."
  exit 1
fi

echo "=========================================="
echo "USB Capture Buffer Validation Test"
echo "=========================================="
echo "Device: $DEV"
echo "Resolution: $TEST_RES"
echo "Duration: ${TEST_DURATION}s"
echo
echo "NOTE: If ffmpeg hangs, the loopback service may be using this device."
echo "Stop it first: sudo systemctl stop usb-capture-ffmpeg.service"
echo

# Test 1: Capture raw frames and monitor for corruption messages
echo "[TEST 1] Capturing at $TEST_RES@30fps for ${TEST_DURATION}s..."
FFMPEG_OUT=$(timeout $((TEST_DURATION + 5)) ffmpeg -hide_banner -loglevel warning -f v4l2 -framerate 30 -video_size "$TEST_RES" -i "$DEV" -t "$TEST_DURATION" -f null - 2>&1 || true)

if [ -z "$FFMPEG_OUT" ]; then
  echo "ERROR: Device not responding or permission denied"
  exit 1
fi

CORRUPT_COUNT=$(echo "$FFMPEG_OUT" | grep -i "corrupted" | wc -l)
TIMEOUT_COUNT=$(echo "$FFMPEG_OUT" | grep -i "timeout" | wc -l)
ERROR_COUNT=$(echo "$FFMPEG_OUT" | grep -i "error" | wc -l)

echo "Results:"
echo "  Corrupted frames: $CORRUPT_COUNT"
echo "  Timeout errors: $TIMEOUT_COUNT"
echo "  Total errors: $ERROR_COUNT"
echo

# Test 2: Try lower resolution if 4K has issues
if [ "$CORRUPT_COUNT" -gt 0 ] || [ "$TIMEOUT_COUNT" -gt 0 ]; then
  echo "[TEST 2] Retesting at 1920x1080 (lower resolution)..."
  FFMPEG_OUT2=$(timeout $((TEST_DURATION + 5)) ffmpeg -hide_banner -loglevel warning -f v4l2 -framerate 30 -video_size 1920x1080 -i "$DEV" -t "$TEST_DURATION" -f null - 2>&1 || true)
  
  CORRUPT_COUNT2=$(echo "$FFMPEG_OUT2" | grep -i "corrupted" | wc -l)
  TIMEOUT_COUNT2=$(echo "$FFMPEG_OUT2" | grep -i "timeout" | wc -l)
  
  echo "Results at 1080p:"
  echo "  Corrupted frames: $CORRUPT_COUNT2"
  echo "  Timeout errors: $TIMEOUT_COUNT2"
  echo
  
  if [ "$CORRUPT_COUNT2" -lt "$CORRUPT_COUNT" ]; then
    echo "✓ RECOMMENDATION: Use 1920x1080 instead of 4K (less corrupted frames)"
    RECOMMENDED_RES="1920x1080"
  else
    echo "✗ ISSUE PERSISTS: Corruption also occurs at 1080p (likely USB/device firmware issue)"
    RECOMMENDED_RES="$TEST_RES"
  fi
else
  echo "✓ NO CORRUPTION DETECTED at $TEST_RES"
  RECOMMENDED_RES="$TEST_RES"
fi

# Test 3: Check USB bus speed and power
echo
echo "[TEST 3] USB Device Info:"
VID_PID=$(lsusb -v -d "$(udevadm info -q property -n "$DEV" 2>/dev/null | grep ID_VENDOR_ID | cut -d= -f2):$(udevadm info -q property -n "$DEV" 2>/dev/null | grep ID_MODEL_ID | cut -d= -f2)" 2>/dev/null | grep "idVendor\|idProduct" | head -2 || echo "N/A")
echo "$VID_PID"

# Check if autosuspend is enabled (which causes latency/timeout)
echo
echo "[TEST 4] USB Power Management:"
for sysdev in /sys/bus/usb/devices/*; do
  if [ -f "$sysdev/power/control" ]; then
    vid=$(cat "$sysdev/idVendor" 2>/dev/null || echo "")
    pid=$(cat "$sysdev/idProduct" 2>/dev/null || echo "")
    if [ -n "$vid" ]; then
      control=$(cat "$sysdev/power/control" 2>/dev/null || echo "unknown")
      echo "  Device $vid:$pid - autosuspend: $control"
    fi
  fi
done

echo
echo "=========================================="
echo "Summary:"
echo "=========================================="
if [ "$CORRUPT_COUNT" -eq 0 ] && [ "$TIMEOUT_COUNT" -eq 0 ]; then
  echo "✓ Device is stable. Recommended resolution: $RECOMMENDED_RES"
  exit 0
elif [ "$CORRUPT_COUNT" -gt 0 ]; then
  echo "✗ Buffer corruption detected. This is a hardware/firmware issue."
  echo "   Workarounds:"
  echo "   1. Use lower resolution: USB_CAPTURE_RES=1920x1080"
  echo "   2. Ensure autosuspend is disabled: sudo ./optimise_device.sh VID:PID"
  echo "   3. Check capture card is receiving valid input signal"
  exit 1
else
  echo "✗ Timeouts detected. USB bandwidth or autosuspend issue."
  echo "   Try: sudo ./optimise_device.sh VID:PID"
  exit 1
fi
