#!/usr/bin/env bash
# OBS Safe Launch Wrapper with USB Device Crash Recovery
# Handles USB capture device disconnections and OBS crashes gracefully
# Integrates with auto-reconnect for v4l2 device recovery
# Monitors OBS and restarts if it crashes due to capture device issues
#
# Usage: obs-safe-launch [--basedir /path/to/op-cap] [--device /dev/video0] [--vidpid 3188:1000] [--no-loopback] [--obs-args "arg1 arg2"]

set -euo pipefail

# Detect BASEDIR: can be overridden via --basedir, otherwise calculate from script location
_SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASEDIR="${_SCRIPT_DIR}"  # Default: parent of scripts directory
DEVICE=""
VIDPID=""
OBS_ARGS=""
SKIP_DEVICE_CHECK=0
LOG_DIR="${HOME}/.cache/obs-safe-launch"
LOG_FILE="$LOG_DIR/obs-crash-$(date +%Y%m%d_%H%M%S).log"
PID_FILE="/tmp/obs-safe-launch-monitor.pid"
FEED_PID_FILE="/tmp/obs-safe-launch-feed.pid"
STREAM_STATE_FILE="/tmp/obs-safe-launch-streaming.state"
MONITOR_INTERVAL=5
RECOVERY_TIMEOUT=3
CRASH_THRESHOLD=3  # Max consecutive crashes before requiring user intervention
CRASH_COUNT=0
WAS_STREAMING=0
AUTO_RESUME_ENABLED=1  # Enable auto-resume by default

# Loopback config
LOOPBACK_DEV="/dev/video10"
LOOPBACK_NR=10
CAP_RES="${USB_CAPTURE_RES:-3840x2160}"
CAP_FPS="${USB_CAPTURE_FPS:-30}"
CAP_FMT="${USB_CAPTURE_FORMAT:-NV12}"
HDR_MODE="${USB_CAPTURE_HDR_MODE:-2}"
USE_LOOPBACK=1

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
usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [-- OBS_ARGS...]

Options:
  --basedir PATH         Path to op-cap project root
  --device DEVNODE       Capture device node (e.g. /dev/video0)
  --vidpid VID:PID       USB VID:PID for reset/rebind recovery
  --obs-args "ARGS"      Extra arguments passed to OBS
  --no-loopback          Skip v4l2loopback/feed.sh and launch OBS direct
  --direct-device        Alias for --no-loopback
  --no-device            Launch OBS without device requirement (configure sources manually)
  --auto-resume          Enable automatic stream resumption after crash (default: enabled)
  --no-auto-resume       Disable automatic stream resumption after crash
  --help                 Show this help

Examples:
  $(basename "$0") --device /dev/usb-video-capture1
  $(basename "$0") --device /dev/usb-video-capture1 --no-loopback
  $(basename "$0") --no-device
  $(basename "$0") --no-device --obs-args "--multiprofile"
EOF
}

parse_args() {
  while (( "$#" )); do
    case "$1" in
      --basedir)
        BASEDIR="$2"; shift 2;;
      --device)
        DEVICE="$2"; shift 2;;
      --vidpid)
        VIDPID="$2"; shift 2;;
      --obs-args)
        OBS_ARGS="$2"; shift 2;;
      --no-loopback|--direct-device)
        USE_LOOPBACK=0; shift;;
      --no-device)
        SKIP_DEVICE_CHECK=1; shift;;
      --auto-resume)
        AUTO_RESUME_ENABLED=1; shift;;
      --no-auto-resume)
        AUTO_RESUME_ENABLED=0; shift;;
      --help|-h)
        usage; exit 0;;
      --)
        shift
        if [ "$#" -gt 0 ]; then
          OBS_ARGS="$OBS_ARGS $*"
        fi
        break;;
      *)
        OBS_ARGS="$OBS_ARGS $1"; shift;;
    esac
  done
}

# Create log directory
setup_logging() {
  mkdir -p "$LOG_DIR"
  log_info "OBS Safe Launch initialized"
  log_info "Project directory: $BASEDIR"
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
# exclusive_caps=0: allows both writer (feed.sh) and readers (OBS) simultaneously
# exclusive_caps=1 would block reading while writing - wrong for our use case
## Scan /sys for any v4l2loopback virtual video device; prints /dev/videoN or empty
_find_loopback_dev() {
  local sysdev
  for sysdev in /sys/devices/virtual/video4linux/video*; do
    [ -d "$sysdev" ] || continue
    local node="/dev/$(basename "$sysdev")"
    [ -c "$node" ] || continue
    # v4l2loopback devices appear as virtual; confirm via v4l2-ctl if available
    if command -v v4l2-ctl &>/dev/null; then
      if v4l2-ctl -d "$node" --info 2>/dev/null | grep -qi "loopback\|Dummy\|USB_Capture_Loop"; then
        echo "$node"; return
      fi
    else
      echo "$node"; return
    fi
  done
}

verify_v4l2loopback() {
  if lsmod | grep -q v4l2loopback; then
    # Module is loaded: find the actual device node (may not be at LOOPBACK_NR)
    local found
    found=$(_find_loopback_dev)

    if [ -n "$found" ]; then
      if [ "$found" != "$LOOPBACK_DEV" ]; then
        log_warn "Loopback found at $found (expected $LOOPBACK_DEV) — updating"
        LOOPBACK_DEV="$found"
      fi

      # Warn if exclusive_caps=1 (blocks readers while feed.sh writes)
      local excaps
      excaps=$(cat /sys/module/v4l2loopback/parameters/exclusive_caps 2>/dev/null | cut -d, -f1)
      if [ "$excaps" = "Y" ]; then
        log_warn "exclusive_caps=1 detected — OBS may get VIDIOC_STREAMON errors. Reload with:"
        log_warn "  sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback video_nr=$LOOPBACK_NR exclusive_caps=0 max_width=3840 max_height=2160"
      fi

      log_ok "v4l2loopback available at $LOOPBACK_DEV"
      return 0
    fi

    # Module loaded but no virtual video node found yet (race); wait briefly
    log_warn "v4l2loopback is loaded but no virtual device node found"
    return 1
  fi

  # Module not loaded: attempt modprobe
  log_info "Loading v4l2loopback (exclusive_caps=0, video_nr=${LOOPBACK_NR})..."
  if ! sudo modprobe v4l2loopback \
      video_nr="$LOOPBACK_NR" \
      card_label="USB_Capture_Loop" \
      exclusive_caps=0 \
      max_width=3840 max_height=2160 2>&1; then
    log_error "sudo modprobe failed. Load the module manually and re-run:"
    log_error "  sudo modprobe v4l2loopback video_nr=$LOOPBACK_NR exclusive_caps=0 max_width=3840 max_height=2160"
    return 1
  fi
  sleep 2

  local found
  found=$(_find_loopback_dev)
  if [ -n "$found" ]; then
    LOOPBACK_DEV="$found"
    log_ok "v4l2loopback loaded at $LOOPBACK_DEV"
    return 0
  fi

  log_error "v4l2loopback loaded but no device node appeared"
  return 1
}

# Start feed.sh: bridge USB device -> v4l2loopback
start_feed() {
  if [ -z "$DEVICE" ]; then
    log_warn "No device specified, skipping feed.sh"
    return 0
  fi

  local feed_script="$BASEDIR/ffmpeg/feed.sh"
  if [ ! -x "$feed_script" ]; then
    log_error "feed.sh not found or not executable at $feed_script"
    return 1
  fi

  log_info "Starting feed.sh: $DEVICE -> $LOOPBACK_DEV (${CAP_RES}@${CAP_FPS} ${CAP_FMT} HDR_MODE=${HDR_MODE})"
  USB_CAPTURE_HDR_MODE="$HDR_MODE" \
    bash "$feed_script" "$DEVICE" "$LOOPBACK_DEV" "$CAP_RES" "$CAP_FPS" "$CAP_FMT" \
    >> "$LOG_FILE" 2>&1 &
  echo $! > "$FEED_PID_FILE"
  log_ok "feed.sh started (PID: $(cat $FEED_PID_FILE))"

  # Give feed.sh a moment to connect and declare format on loopback
  sleep 3

  if ! kill -0 "$(cat $FEED_PID_FILE)" 2>/dev/null; then
    log_error "feed.sh died immediately - check device and log: $LOG_FILE"
    return 1
  fi
}

# Watchdog: restart feed.sh if it dies, without restarting OBS
supervise_feed() {
  while true; do
    sleep 5
    local fpid
    fpid=$(cat "$FEED_PID_FILE" 2>/dev/null || echo "")
    if [ -z "$fpid" ] || ! kill -0 "$fpid" 2>/dev/null; then
      log_warn "feed.sh died (PID: ${fpid:-unknown}). Restarting in 2s..."
      sleep 2
      start_feed || log_error "feed.sh restart failed"
    fi
  done
}

# Stop feed.sh
stop_feed() {
  if [ -f "$FEED_PID_FILE" ]; then
    local fpid
    fpid=$(cat "$FEED_PID_FILE")
    if kill -0 "$fpid" 2>/dev/null; then
      log_info "Stopping feed.sh (PID: $fpid)"
      kill -TERM "$fpid" 2>/dev/null || true
      sleep 2
      kill -9 "$fpid" 2>/dev/null || true
    fi
    rm -f "$FEED_PID_FILE"
  fi
  # Kill any orphaned ffmpeg pointing at the USB device
  pkill -f "ffmpeg.*usb-video-capture" 2>/dev/null || true
}

# Start auto-reconnect monitor if device specified
start_auto_reconnect() {
  if [ -z "$DEVICE" ]; then
    log_info "Skipping auto-reconnect (no device specified)"
    return 0
  fi

  if [ ! -f "$BASEDIR/scripts/auto_reconnect.sh" ]; then
    log_warn "auto_reconnect.sh not found at $BASEDIR/scripts/"
    return 1
  fi

  if [ -z "$VIDPID" ]; then
    log_warn "VIDPID not specified — auto-reconnect will watch device node only"
  fi

  log_info "Starting auto-reconnect monitor for $DEVICE (${VIDPID:-device-watch mode})..."
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

  # Verify BASEDIR exists
  if [ ! -d "$BASEDIR" ]; then
    log_error "Project directory not found: $BASEDIR"
    log_error "Specify correct path with: --basedir /path/to/op-cap"
    exit 1
  fi

  if [ ! -d "$BASEDIR/scripts" ]; then
    log_error "Scripts directory not found: $BASEDIR/scripts"
    log_error "BASEDIR seems incorrect: $BASEDIR"
    exit 1
  fi

  # Check for required commands
  for cmd in obs v4l2-ctl; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "$cmd not found. Install with: sudo apt install $cmd"
      exit 1
    fi
  done

  # Check if device specified and accessible
  if [ "$SKIP_DEVICE_CHECK" -eq 0 ]; then
    if [ -n "$DEVICE" ]; then
      if ! check_usb_device "$DEVICE"; then
        log_warn "USB device $DEVICE may be inaccessible. Continuing anyway..."
        log_info "If connection issues persist, check:"
        log_info "  - lsusb (device enumerated?)"
        log_info "  - dmesg (driver errors?)"
        log_info "  - sudo $BASEDIR/scripts/validate_capture.sh $DEVICE"
        log_warn ""
        log_warn "To launch OBS without a device and configure sources manually,"
        log_warn "run with --no-device flag."
      fi
    fi
  else
    log_info "Device checks skipped (--no-device flag). Configure sources manually in OBS."
  fi

  # Verify v4l2loopback if using isolation mode
  if [ "$USE_LOOPBACK" -eq 1 ]; then
    verify_v4l2loopback || log_warn "v4l2loopback not available (no device isolation)"
  else
    log_info "Loopback mode disabled (--no-loopback): OBS will use capture device directly"
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

# Check if OBS was streaming via websocket or log file
detect_streaming_state() {
  # Check recent log for streaming indicators
  if [ ! -f "$LOG_FILE" ]; then
    log_info "Log file doesn't exist yet: $LOG_FILE"
    return 1
  fi
  
  if tail -100 "$LOG_FILE" 2>/dev/null | grep -q "==== Streaming Start"; then
    log_info "Detected active stream (found 'Streaming Start' in log)"
    echo "1" > "$STREAM_STATE_FILE"
    return 0
  fi
  log_info "No active stream found in logs"
  return 1
}

# Handle OBS exit and decide whether to recover/restart
handle_obs_exit() {
  set +e  # Disable error exit for this function
  local exit_code="$1"
  
  # Detect if OBS was streaming before crash
  detect_streaming_state && WAS_STREAMING=1
  
  log_warn "OBS process exited with code: $exit_code"

  # Check if this was a crash (non-zero exit or signal)
  if [ "$exit_code" -ne 0 ]; then
    CRASH_COUNT=$((CRASH_COUNT + 1))
    log_info "CRASH_COUNT incremented to: $CRASH_COUNT"

    if [ $CRASH_COUNT -gt $CRASH_THRESHOLD ]; then
      log_error "OBS crashed $CRASH_COUNT times (threshold: $CRASH_THRESHOLD). Requiring user intervention."
      set -e
      return 1
    fi

    log_recovery "Attempting recovery (crash $CRASH_COUNT/$CRASH_THRESHOLD)"
    log_recovery "Waiting ${RECOVERY_TIMEOUT}s before restart..."
    sleep $RECOVERY_TIMEOUT

    # Restart auto-reconnect if it died
    if [ -n "$DEVICE" ]; then
      if ! kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        log_recovery "Auto-reconnect died, restarting..."
        start_auto_reconnect || log_recovery "Auto-reconnect restart failed"
      fi
    fi
    
    # Add --startstreaming flag if OBS was streaming before crash and auto-resume is enabled
    if [ "$AUTO_RESUME_ENABLED" -eq 1 ] && [ "$WAS_STREAMING" -eq 1 ]; then
      if [[ ! "$OBS_ARGS" =~ "--startstreaming" ]]; then
        log_recovery "Auto-resuming stream after crash recovery"
        OBS_ARGS="$OBS_ARGS --startstreaming"
      fi
    fi

    log_recovery "Returning 0 (continue loop)"
    set -e
    return 0
  else
    CRASH_COUNT=0
    log_info "Clean exit, resetting crash count"
    set -e
    return 0
  fi
}

# Main launcher loop
main() {
  parse_args "$@"
  setup_logging

  log_ok "=== OBS Safe Launch Wrapper ==="
  log_info "PROJECT_DIR: $BASEDIR"
  log_info "DEVICE: ${DEVICE:-none}"
  log_info "VIDPID: ${VIDPID:-none}"
  log_info "MODE: $([ "$USE_LOOPBACK" -eq 1 ] && echo "loopback" || echo "direct-device")"
  log_info "DEVICE_CHECK: $([ "$SKIP_DEVICE_CHECK" -eq 1 ] && echo "disabled" || echo "enabled")"
  log_info "OBS_ARGS: ${OBS_ARGS:-none}"

  pre_flight_checks
  load_driver_optimizations

  # Set up cleanup trap early
  trap 'cleanup' EXIT INT TERM

  if [ "$USE_LOOPBACK" -eq 1 ]; then
    # Step 1: load loopback
    verify_v4l2loopback || { log_error "Cannot continue without v4l2loopback"; exit 1; }

    # Step 2: start feed.sh to bridge USB -> loopback, supervise it in background
    start_feed
    supervise_feed &
    local supervisor_pid=$!
    echo "$supervisor_pid" >> "$PID_FILE"

    log_info "Launching OBS pointed at loopback: $LOOPBACK_DEV"
    log_info "OBS should NOT be configured to open $DEVICE directly"
  else
    log_info "Skipping loopback/feed (--no-loopback)"
    if [ -n "$DEVICE" ]; then
      log_info "Configure OBS source to use device directly: $DEVICE"
    fi
  fi

  # Step 3: start auto-reconnect monitor for USB device recovery (only if device specified)
  if [ "$SKIP_DEVICE_CHECK" -eq 0 ]; then
    start_auto_reconnect
  else
    log_info "Device monitoring disabled (--no-device): OBS is protected from crash-restart loops only"
  fi
  echo ""

  # Main loop: launch OBS, restart on crash
  while true; do
    export GSETTINGS_SCHEMA_DIR=/usr/share/glib-2.0/schemas

    set +e  # Disable exit-on-error for OBS execution
    obs $OBS_ARGS 2>&1 | tee -a "$LOG_FILE"
    EXIT_CODE=${PIPESTATUS[0]}
    set -e  # Re-enable exit-on-error
    
    log_info "OBS exited with code: $EXIT_CODE"
    
    if [ $EXIT_CODE -eq 0 ]; then
      log_info "OBS exited normally"
      CRASH_COUNT=0
      break
    else
      log_info "Calling handle_obs_exit with exit code: $EXIT_CODE"
      handle_obs_exit "$EXIT_CODE"
      HANDLE_RESULT=$?
      log_info "handle_obs_exit returned: $HANDLE_RESULT"
      
      if [ $HANDLE_RESULT -ne 0 ]; then
        log_info "Recovery failed, breaking loop"
        break
      else
        log_info "Recovery approved, restarting OBS in loop"
      fi
    fi
  done

  log_info "OBS Safe Launch wrapper exiting"
}

# Cleanup function
cleanup() {
  log_info "Cleaning up..."
  stop_feed
  stop_auto_reconnect
  rm -f "$PID_FILE" "$STREAM_STATE_FILE"
  log_info "Shutdown complete"
}

main "$@"
