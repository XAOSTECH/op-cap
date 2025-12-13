#!/usr/bin/env bash
# Interactive maintenance menu for USB capture device troubleshooting
# Dynamically discovers and loads scripts from scripts/maintenance/
# Each script declares: MAINTENANCE_DESC, MAINTENANCE_ARGS
# Usage: ./scripts/maintenance.sh

set -euo pipefail

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
MAINTENANCE_DIR="$BASEDIR/maintenance"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

header() {
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}========================================${NC}"
}

info() {
  echo -e "${GREEN}[*]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[!]${NC} $1"
}

error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Load script metadata by sourcing MAINTENANCE_* variables
# Returns: name, desc, args (as globals)
load_script_metadata() {
  local script="$1"
  local -x MAINTENANCE_DESC=""
  local -x MAINTENANCE_ARGS=""
  
  # Source only variable declarations (safe: no execution)
  eval "$(grep '^MAINTENANCE_' "$script" | head -5)"
  
  echo "$MAINTENANCE_DESC"
}

load_script_args() {
  local script="$1"
  eval "$(grep '^MAINTENANCE_ARGS=' "$script" | head -1)"
  echo "$MAINTENANCE_ARGS"
}

# Detect USB video devices
detect_devices() {
  echo
  info "Detecting USB capture devices..."
  echo
  
  if ! command -v lsusb &>/dev/null; then
    error "lsusb not found. Install usbutils."
    return 1
  fi
  
  # Show all USB devices with video-related keywords
  lsusb | grep -iE "camera|video|hdmi|capture|264|551|544|3188" || {
    warn "No obvious video devices found. Showing all USB devices:"
    lsusb
  }
  echo
}

# Resolve user input to valid USB bus path
# Accepts: "2:5" (bus:device) or "2-1" (sysfs) or "3188:1000" (VID:PID)
resolve_usb_bus() {
  local input="$1"
  
  # If it's already a valid sysfs path (contains a dash), verify it exists
  if [[ "$input" =~ ^[0-9]+-[0-9] ]]; then
    if [ -d "/sys/bus/usb/devices/$input" ]; then
      echo "$input"
      return 0
    else
      return 1
    fi
  fi
  
  # If it's Bus:Device format (e.g., "2:5"), find it in sysfs
  if [[ "$input" =~ ^([0-9]+):([0-9]+)$ ]]; then
    local busnum="${BASH_REMATCH[1]}"
    local devnum="${BASH_REMATCH[2]}"
    
    # Search for device with matching busnum and devnum
    # Note: Search all devices including those in unauthorized state
    for D in /sys/bus/usb/devices/*-*; do
      if [[ -f "$D/busnum" && -f "$D/devnum" ]]; then
        local b=$(cat "$D/busnum" 2>/dev/null || echo "")
        local d=$(cat "$D/devnum" 2>/dev/null || echo "")
        if [[ "$b" == "$busnum" && "$d" == "$devnum" ]]; then
          local bus=$(basename "$D")
          echo "Resolved Bus $busnum Device $devnum → $bus" >&2
          echo "$bus"
          return 0
        fi
      fi
    done
    return 1
  fi
  
  # If it's VID:PID, find the device (search both authorized and unauthorized)
  if [[ "$input" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
    local vid=$(echo "$input" | cut -d: -f1)
    local pid=$(echo "$input" | cut -d: -f2)
    
    # Search in both *-* (hub ports) and root hubs
    for D in /sys/bus/usb/devices/*; do
      if [[ -f "$D/idVendor" && -f "$D/idProduct" ]]; then
        if [[ "$(cat "$D/idVendor" 2>/dev/null || echo "")" == "$vid" && \
              "$(cat "$D/idProduct" 2>/dev/null || echo "")" == "$pid" ]]; then
          local bus=$(basename "$D")
          # Skip if it's a device/configuration node (ends with :x.y), we need the hub port
          if [[ ! "$bus" =~ :[0-9] ]]; then
            echo "Resolved VID:PID $input → $bus" >&2
            echo "$bus"
            return 0
          fi
        fi
      fi
    done
    return 1
  fi
  
  return 1
}

# Parse maintenance scripts and build menu
build_menu() {
  local -a SCRIPTS=()
  local -a DESCRIPTIONS=()
  local -a ARG_TYPES=()
  
  if [ ! -d "$MAINTENANCE_DIR" ]; then
    error "Maintenance directory not found: $MAINTENANCE_DIR"
    return 1
  fi
  
  # Scan maintenance scripts and extract metadata
  for script in "$MAINTENANCE_DIR"/*.sh; do
    if [ -f "$script" ] && [ -x "$script" ]; then
      local name=$(basename "$script" .sh)
      local desc=$(load_script_metadata "$script")
      local args=$(load_script_args "$script")
      
      SCRIPTS+=("$name")
      DESCRIPTIONS+=("${desc:-Unknown tool}")
      ARG_TYPES+=("${args:-none}")
    fi
  done
  
  # Add special hub control entries (reuse usb_reset script)
  SCRIPTS+=("usb_reset" "usb_reset" "usb_reset")
  DESCRIPTIONS+=("Disable USB hub/device (force disconnect)" "Enable USB hub/device (force reconnect)" "Authorize device (enable after boot block)")
  ARG_TYPES+=("hub_disable" "hub_enable" "hub_authorize")
  
  if [ ${#SCRIPTS[@]} -eq 0 ]; then
    error "No maintenance scripts found in $MAINTENANCE_DIR"
    return 1
  fi
  
  # Display menu
  echo
  info "Available maintenance tools:"
  echo
  
  for i in "${!SCRIPTS[@]}"; do
    printf "${GREEN}%d${NC}) %-25s %s\n" $((i+1)) "${SCRIPTS[$i]}" "${DESCRIPTIONS[$i]}"
  done
  echo
  printf "${GREEN}0${NC}) Exit\n"
  echo
  
  # Get user choice
  read -p "Select tool (0-${#SCRIPTS[@]}): " choice
  
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 0 ] || [ "$choice" -gt ${#SCRIPTS[@]} ]; then
    error "Invalid choice"
    return 1
  fi
  
  if [ "$choice" -eq 0 ]; then
    echo "Exiting..."
    exit 0
  fi
  
  local selected_script="${SCRIPTS[$((choice-1))]}"
  local arg_type="${ARG_TYPES[$((choice-1))]}"
  local script_path="$MAINTENANCE_DIR/$selected_script.sh"
  
  run_maintenance_script "$selected_script" "$script_path" "$arg_type"
}

run_maintenance_script() {
  local name="$1"
  local path="$2"
  local arg_type="$3"
  
  echo
  header "Running: $name"
  echo
  
  # Handle arguments based on arg_type declared in script
  case "$arg_type" in
    vidpid)
      echo "This tool requires a device VID:PID (e.g., 3188:1000)"
      detect_devices
      
      read -p "Enter VID:PID (or blank to auto-detect): " vidpid
      
      if [ -z "$vidpid" ]; then
        read -p "Enter device path (e.g., /dev/video0): " devpath
        if [ -z "$devpath" ]; then
          error "No device specified"
          return 1
        fi
        vidpid=$(udevadm info -q property -n "$devpath" 2>/dev/null | awk -F= '/ID_VENDOR_ID=/{v=$2}/ID_MODEL_ID=/{printf "%s:%s\n", v,$2}' || echo "")
        if [ -z "$vidpid" ]; then
          error "Could not detect VID:PID from device"
          return 1
        fi
      fi
      
      info "Running with VID:PID: $vidpid"
      "$path" "$vidpid"
      ;;
      
    device_path)
      read -p "Enter device path (default: /dev/video0): " devpath
      devpath=${devpath:-/dev/video0}
      "$path" "$devpath"
      ;;
      
    vidpid_optional)
      detect_devices
      read -p "Enter VID:PID to search (blank for all devices): " vidpid
      if [ -z "$vidpid" ]; then
        "$path"
      else
        "$path" "$vidpid"
      fi
      ;;
      
    vidpid_and_hubport)
      echo "This will attempt full USB device recovery."
      detect_devices
      
      read -p "Enter VID:PID of device to repair: " vidpid
      if [ -z "$vidpid" ]; then
        error "VID:PID required"
        return 1
      fi
      
      read -p "Optional: Hub port to power cycle (e.g., 1-1.4, blank to skip): " hubport
      
      if [ -n "$hubport" ]; then
        "$path" --vidpid "$vidpid" --hub "$hubport"
      else
        "$path" --vidpid "$vidpid"
      fi
      ;;
      
    hubport)
      read -p "Enter hub port (e.g., 1-1.4): " hubport
      if [ -z "$hubport" ]; then
        error "Hub port required"
        return 1
      fi
      "$path" "$hubport"
      ;;
      
    hub_control)
      detect_devices
      
      echo
      echo "Choose hub control action:"
      echo "1) Disable USB hub/device (force disconnect)"
      echo "2) Enable USB hub/device (force reconnect)"
      read -p "Select action (1-2): " hub_action
      
      read -p "Enter USB bus number (e.g., 2-1, 1-1.4): " bus
      if [ -z "$bus" ]; then
        error "Bus number required"
        return 1
      fi
      
      case "$hub_action" in
        1)
          info "Disabling hub: $bus"
          sudo "$path" --disable-hub "$bus"
          ;;
        2)
          info "Enabling hub: $bus"
          sudo "$path" --enable-hub "$bus"
          ;;
        *)
          error "Invalid action"
          return 1
          ;;
      esac
      ;;
      
    hub_disable)
      local max_retries=3
      local retry_count=0
      local success=false
      
      while [ $retry_count -lt $max_retries ] && [ "$success" = false ]; do
        if [ $retry_count -eq 0 ]; then
          detect_devices
          echo
          warn "You can enter (all refer to the same UGREEN device):"
          warn "  2:5         → Bus 2, Device 5"
          warn "  2-1         → sysfs path (direct)"
          warn "  3188:1000   → VID:PID (auto-lookup)"
          echo
        fi
        
        read -p "Enter USB device identifier: " bus_input
        if [ -z "$bus_input" ]; then
          error "Input required"
          ((retry_count++))
          continue
        fi
        
        bus=$(resolve_usb_bus "$bus_input" 2>/dev/null) || {
          error "Invalid input: '$bus_input' not found"
          ((retry_count++))
          continue
        }
        
        info "Disabling hub: $bus"
        if "$path" --disable-hub "$bus" 2>&1; then
          success=true
        else
          error "Failed to disable hub '$bus'"
          ((retry_count++))
        fi
      done
      
      if [ "$success" = false ]; then
        error "Failed to disable hub"
        return 1
      fi
      ;;
      
    hub_enable)
      local max_retries=3
      local retry_count=0
      local success=false
      
      while [ $retry_count -lt $max_retries ] && [ "$success" = false ]; do
        if [ $retry_count -eq 0 ]; then
          detect_devices
          echo
          warn "You can enter (all refer to the same UGREEN device):"
          warn "  2:5         → Bus 2, Device 5"
          warn "  2-1         → sysfs path (direct)"
          warn "  3188:1000   → VID:PID (auto-lookup)"
          echo
        fi
        
        read -p "Enter USB device identifier: " bus_input
        if [ -z "$bus_input" ]; then
          error "Input required"
          ((retry_count++))
          continue
        fi
        
        bus=$(resolve_usb_bus "$bus_input" 2>/dev/null) || {
          error "Invalid input: '$bus_input' not found"
          ((retry_count++))
          continue
        }
        
        info "Enabling hub: $bus"
        if "$path" --enable-hub "$bus" 2>&1; then
          success=true
        else
          error "Failed to enable hub '$bus'"
          ((retry_count++))
        fi
      done
      
      if [ "$success" = false ]; then
        error "Failed to enable hub"
        return 1
      fi
      ;;
      
    hub_authorize)
      local max_retries=3
      local retry_count=0
      local success=false
      
      while [ $retry_count -lt $max_retries ] && [ "$success" = false ]; do
        if [ $retry_count -eq 0 ]; then
          detect_devices
          echo
          warn "Authorize device that was kept disabled on boot via udev rule."
          warn "Use this to enable the device when ready to use in OBS."
          echo
          warn "You can enter:"
          warn "  2:5         → Bus 2, Device 5"
          warn "  2-1         → sysfs path (direct)"
          warn "  3188:1000   → VID:PID (auto-lookup)"
          echo
        fi
        
        read -p "Enter USB device identifier: " bus_input
        if [ -z "$bus_input" ]; then
          error "Input required"
          ((retry_count++))
          continue
        fi
        
        bus=$(resolve_usb_bus "$bus_input" 2>/dev/null) || {
          error "Invalid input: '$bus_input' not found"
          ((retry_count++))
          continue
        }
        
        info "Authorizing device: $bus"
        if "$path" --authorize "$bus" 2>&1; then
          success=true
        else
          error "Failed to authorize device '$bus'"
          ((retry_count++))
        fi
      done
      
      if [ "$success" = false ]; then
        error "Failed to authorize device"
        return 1
      fi
      ;;
      
    none|*)
      # Script handles its own argument prompting
      "$path"
      ;;
  esac
  
  echo
  info "Script completed"
  echo
}

# Main menu loop
main() {
  header "USB Capture Device Maintenance"
  
  while true; do
    build_menu || true
    
    read -p "Run another tool? (y/n): " again
    if [[ ! "$again" =~ ^[Yy]$ ]]; then
      break
    fi
    clear
    header "USB Capture Device Maintenance"
  done
  
  echo "Exiting maintenance menu."
}

# Start
main
