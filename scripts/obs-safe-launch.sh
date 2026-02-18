#!/usr/bin/env bash
# OBS Safe Launch Wrapper with USB Device Crash Recovery
# Handles USB capture device disconnections and OBS crashes gracefully
# Integrates with auto-reconnect for v4l2 device recovery
# Monitors OBS and restarts if it crashes due to capture device issues
#
# Usage: obs-safe-launch [--device /dev/video0] [--vidpid 3188:1000] [--obs-args "arg1 arg2"]

set -euo pipefail

BASEDIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE=""
VIDPID=""
OBS_ARGS=""
LOG_DIR="${HOME}/.cache/obs-safe-launch"
LOG_FILE="$LOG_DIR/obs-crash-$(date +%Y%m%d_%H%M%S).log"
PID_FILE="/tmp/obs-safe-launch-monitor.pid"
MONITOR_INTERVAL=5
RECOVERY_TIMEOUT=30
CRASH_THRESHOLD=3  # Max consecutive crashes before requiring user intervention
CRASH_COUNT=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Logging functions
log_info() {
  echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} INFO: $*" | tee -a "$LOG_FILE"
}

log_ok() {
  echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} OK: $*" | tee -a "$LOG_FILE"
}

log_warn() {
  echo -e "${YELLOW}[$(date +'%H:%M:%S')]${NC} WARN: $*" | tee -a "$LOG_FILE"
}

log_error() {
  echo -e "${RED}[$(date +'%H:%M:%S')]${NC} ERROR: $*" | tee -a "$LOG_FILE"
}

log_recovery() {
  echo -e "${MAGENTA}[$(date +'%H:%M:%S')]${NC} RECOVERY: $*" | tee -a "$LOG_FILE"
}

# Parse command-line arguments
parse_args() {
  while (( "$#" )); do
    case "$1" in
      --device)
        DEVICE="$2"; shift 2;;
      --vidpid)
        VIDPID="$2"; shift 2;;
      --obs-args)
        OBS_ARGS="$2"; shift 2;;
      *)
        OBS_ARGS="$OBS_ARGS $1"; shift;;
    esac
  done
}

# Create log directory
setup_logging() {
  mkdir -p "$LOG_DIR"
  log_info "OBS Safe Launch initialized"
  log_info "Log file: $LOG_FILE"
}

# Check if USB device exists and is healthy
check_usb_device() {
  local dev="${1:-}"
  if [ -z "$dev" ]; then
    return 0  # No device specified, skip check
  fi

  if [ ! -c "$dev" ]; then
    log_warn "USB device $dev not found (may be disconnected)"
    return 1
  fi

  # Try to get basic device info
  if ! v4l2-ctl -d "$dev" --get-fmt-video &>/dev/null 2>&1; then
    log_warn "USB device $dev not responding to v4l2 commands"
    return 1
  fi

  log_ok "USB device $dev is healthy"
  return 0
}

# Check v4l2loopback is loaded
verify_v4l2loopback() {
  if ! lsmod | grep -q v4l2loopback; then
    log_info "Loading v4l2loopback module..."
    if ! sudo modprobe v4l2loopback video_nr=10 card_label="USB_Capture_Loop" exclusive_caps=1 2>&1; then
      log_warn "Failed to load v4l2loopback (may not be installed)"
      return 1
    fi
    sleep 2
  fi

  if [ -c /dev/video10 ]; then
    log_ok "v4l2loopback available at /dev/video10"
    return 0
  fi

  log_warn "v4l2loopback module loaded but /dev/video10 not found"
  return 1
}

# Start auto-reconnect monitor if device specified
start_auto_reconnect() {
  if [ -z "$DEVICE" ] || [ -z "$VIDPID" ]; then
    log_info "Skipping auto-reconnect (no device/vidpid specified)"
    return 0
  fi

  if [ ! -f "$BASEDIR/scripts/auto_reconnect.sh" ]; then
    log_warn "auto_reconnect.sh not found at $BASEDIR/scripts/"
    return 1
  fi

  log_info "Starting auto-reconnect monitor for $DEVICE ($VIDPID)..."
  # Run auto-reconnect in background
  sudo bash "$BASEDIR/scripts/auto_reconnect.sh" \
    --vidpid "$VIDPID" \
    --device "$DEVICE" \
    --ffmpeg-service "usb-capture-ffmpeg.service" \
    &>> "$LOG_FILE" &

  # Save monitor PID
  echo $! > "$PID_FILE"
  log_ok "Auto-reconnect monitor started (PID: $(cat "$PID_FILE"))"
}

# Stop auto-reconnect monitor
stop_auto_reconnect() {
  if [ -f "$PID_FILE" ]; then
    local PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
      log_info "Stopping auto-reconnect monitor (PID: $PID)"
      sudo kill "$PID" 2>/dev/null || true
      sleep 2
    fi
    rm -f "$PID_FILE"
  fi
}

# Pre-flight checks
pre_flight_checks() {
  log_info "Running pre-flight checks..."

  # Check for required commands
  for cmd in obs v4l2-ctl; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "$cmd not found. Install with: sudo apt install $cmd"
      exit 1
    fi
  done

  # Check if device specified and accessible
  if [ -n "$DEVICE" ]; then
    if ! check_usb_device "$DEVICE"; then
      log_warn "USB device $DEVICE may be inaccessible. Continuing anyway..."
      log_info "If connection issues persist, check:"
      log_info "  - lsusb (device enumerated?)"
      log_info "  - dmesg (driver errors?)"
      log_info "  - sudo ./scripts/validate_capture.sh $DEVICE"
    fi
  fi

  # Verify v4l2loopback if using isolation
  if [ -z "$DEVICE" ] || [ "$DEVICE" = "/dev/video10" ]; then
    verify_v4l2loopback || log_warn "v4l2loopback not available (no device isolation)"
  fi

  log_ok "Pre-flight checks complete"
}

# Load GPU driver optimizations
load_driver_optimizations() {
  if [ -f /etc/profile.d/obs-wayland.sh ]; then
    log_info "Loading driver optimizations from /etc/profile.d/obs-wayland.sh"
    source /etc/profile.d/obs-wayland.sh
    log_ok "Driver optimizations loaded"
  else
    log_warn "GPU driver optimizations not found. Run: sudo make optimise-drivers"
  fi
}

# Monitor OBS process and handle crashes
monitor_obs() {
  local obs_pid=$1

  log_info "Monitoring OBS process (PID: $obs_pid)"

  while kill -0 "$obs_pid" 2>/dev/null; do
    sleep $MONITOR_INTERVAL
  done

  local exit_code=$?
  log_warn "OBS process exited with code: $exit_code"

  # Check if this was a crash (non-zero exit or signal)
  if [ $exit_code -ne 0 ]; then
    ((CRASH_COUNT++))

    if [ $CRASH_COUNT -ge $CRASH_THRESHOLD ]; then
      log_error "OBS crashed $CRASH_COUNT times. Requiring user intervention."
      log_error "Common causes:"
      log_error "  - USB device disconnected (check journalctl -u usb-capture-ffmpeg.service)"
      log_error "  - Buffer corruption (run: sudo ./scripts/validate_capture.sh $DEVICE)"
      log_error "  - GPU driver issue (run: sudo make optimise-drivers)"
      return 1
    fi

    log_recovery "Attempting recovery (crash $CRASH_COUNT/$CRASH_THRESHOLD)"
    log_recovery "Waiting ${RECOVERY_TIMEOUT}s before restart..."
    sleep $RECOVERY_TIMEOUT

    # Restart auto-reconnect if it died
    if [ -n "$DEVICE" ] && [ -n "$VIDPID" ]; then
      if ! kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        log_recovery "Auto-reconnect died, restarting..."
        start_auto_reconnect
      fi
    fi

    return 0
  else
    CRASH_COUNT=0
    return 0
  fi
}

# Main launcher loop
main() {
  parse_args "$@"
  setup_logging

  log_ok "=== OBS Safe Launch Wrapper ==="
  log_info "DEVICE: ${DEVICE:-none}"
  log_info "VIDPID: ${VIDPID:-none}"
  log_info "OBS_ARGS: ${OBS_ARGS:-none}"

  pre_flight_checks
  load_driver_optimizations
  start_auto_reconnect

  # Set up cleanup trap
  trap 'cleanup' EXIT INT TERM

  log_info "Launching OBS..."
  echo ""

  # Main loop: launch OBS and restart if it crashes
  while true; do
    # Prepare OBS environment
    export GSETTINGS_SCHEMA_DIR=/usr/share/glib-2.0/schemas

    # Launch OBS
    if obs $OBS_ARGS; then
      # Clean exit
      log_info "OBS exited normally"
      CRASH_COUNT=0
      break
    else
      EXIT_CODE=$?
      # OBS crashed or had an error
      if ! monitor_obs $$; then
        # Crash threshold exceeded
        break
      fi
    fi
  done

  log_info "OBS Safe Launch wrapper exiting"
}

# Cleanup function
cleanup() {
  log_info "Cleaning up..."
  stop_auto_reconnect
  rm -f "$PID_FILE"
  log_info "Shutdown complete"
}

main "$@"
