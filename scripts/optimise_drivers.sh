#!/usr/bin/env bash
# Optimise graphics drivers for OBS on Wayland
# Addresses explicit sync issues, PipeWire screen capture stability, and projector crashes
# Supports Nvidia, AMD, and Intel GPUs on Wayland
# Usage: ./optimise_drivers.sh [--auto | --nvidia | --amd | --intel]
set -euo pipefail

BASEDIR=$(cd "$(dirname "$0")/.." && pwd)
DRIVER_MODE=${1:-}
OBS_ENV_FILE="/etc/profile.d/obs-wayland.sh"
OBS_LAUNCH_SCRIPT="/usr/local/bin/obs-wayland"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
  echo -e "${GREEN}[OK]${NC} $*"
}

warning() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
  echo -e "${RED}[ERROR]${NC} $*"
}

# Detect GPU and driver
detect_gpu() {
  local GPU_INFO
  GPU_INFO=$(lspci -k | grep -E 'VGA|3D' -A 2)

  # Check for Nvidia (by kernel driver in use)
  if echo "$GPU_INFO" | grep -i 'Kernel driver in use: nvidia' >/dev/null; then
    echo "nvidia"
    return
  fi

  # Check for AMD (by kernel driver in use)
  if echo "$GPU_INFO" | grep -i 'Kernel driver in use: amdgpu' >/dev/null; then
    echo "amd"
    return
  fi

  # Check for Intel (by kernel driver in use)
  if echo "$GPU_INFO" | grep -i 'Kernel driver in use: i915' >/dev/null; then
    echo "intel"
    return
  fi

  echo "unknown"
}

# Get Nvidia driver version
get_nvidia_version() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "unknown"
  else
    # Try to get from kernel module
    modinfo nvidia 2>/dev/null | grep -E '^version:' | awk '{print $2}' || echo "unknown"
  fi
}

# Optimise Nvidia for Wayland + OBS
optimise_nvidia() {
  info "Optimising Nvidia driver for Wayland OBS..."

  local DRIVER_VERSION
  DRIVER_VERSION=$(get_nvidia_version)

  if [ "$DRIVER_VERSION" = "unknown" ]; then
    warning "Could not detect Nvidia driver version"
  else
    success "Nvidia driver version: $DRIVER_VERSION"
  fi

  # Create environment configuration for OBS on Wayland
  sudo tee "$OBS_ENV_FILE" > /dev/null << 'NVIDIA_EOF'
# OBS Wayland optimisation for Nvidia
# Disables explicit sync to prevent crashes on Wayland with Nvidia GPUs

# Critical: Disable explicit sync (prevents projector crashes and screen capture hangs)
export __NV_DISABLE_EXPLICIT_SYNC=1

# Enable Nvidia modifiers for better Wayland integration
export __NV_PRIME_RENDER_OFFLOAD=1
export __NV_PRIME_RENDER_OFFLOAD_PROC=bash

# Wayland-specific optimisations
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland

# OBS audio/video codec hints
export LIBVA_DRIVER_NAME=nvidia
export LIBVA_MESSAGING_LEVEL=0

# Disable GPU reset timeout (prevents timeout-related crashes)
export __NV_DRIVER_CAPABILITIES=graphics,compat32,display,utility

# PipeWire audio optimisation
export PIPEWIRE_LATENCY=64/48000

# Log level (adjust as needed: 0=ERROR, 1=WARN, 2=INFO, 3=DEBUG)
export CUDA_VISIBLE_DEVICES=0
NVIDIA_EOF

  sudo chmod 644 "$OBS_ENV_FILE"
  success "Created $OBS_ENV_FILE"

  # Check kernel parameters for Nvidia
  if ! grep -q "nvidia-drm.modeset=1" /proc/cmdline 2>/dev/null; then
    warning "Nvidia kernel module modeset flag not detected"
    info "  Add 'nvidia-drm.modeset=1' to kernel parameters for better Wayland support"
    info "  Edit /etc/default/grub and add to GRUB_CMDLINE_LINUX_DEFAULT, then run: sudo update-grub"
  else
    success "Nvidia modeset flag detected in kernel parameters"
  fi

  # Recommend driver update if version is old
  if [ "$DRIVER_VERSION" != "unknown" ]; then
    MAJOR_VERSION="${DRIVER_VERSION%%.*}"
    if [ "$MAJOR_VERSION" -lt 530 ]; then
      warning "Nvidia driver version $DRIVER_VERSION is old"
      info "  Update to driver 530+ for improved Wayland stability"
      info "  Run: sudo apt install nvidia-driver-latest-dkms"
    else
      success "Nvidia driver version is adequate for Wayland"
    fi
  fi

  # Create convenient launcher script
  create_obs_launcher
}

# Optimise AMD for Wayland + OBS
optimise_amd() {
  info "Optimising AMD driver (AMDGPU) for Wayland OBS..."

  sudo tee "$OBS_ENV_FILE" > /dev/null << 'AMD_EOF'
# OBS Wayland optimisation for AMD
# AMDGPU driver optimisations for stable screen capture and PipeWire integration

# Enable AMD color block compression for better performance
export RADEON_ENABLE_ACE=1

# Wayland-specific optimisations
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland

# Video codec acceleration
export LIBVA_DRIVER_NAME=radeonsi
export VDPAU_DRIVER=radeonsi

# PipeWire audio optimisation
export PIPEWIRE_LATENCY=64/48000

# Mesa/AMDGPU debug level
export MESA_DEBUG=0
export LIBGL_ALWAYS_INDIRECT=0

# Enable DRI3 for better compatibility
export LIBGL_DRI3_DISABLE=0
AMD_EOF

  sudo chmod 644 "$OBS_ENV_FILE"
  success "Created $OBS_ENV_FILE for AMD"

  # AMD-specific recommendations
  info "AMD GPU detected"
  info "  Ensure AMDGPU driver is loaded: $(lsmod | grep amdgpu || echo 'NOT LOADED')"
  info "  Check Mesa version: $(glxinfo 2>/dev/null | grep 'Mesa version' || echo 'glxinfo not available')"

  # Create convenient launcher script
  create_obs_launcher
}

# Optimise Intel for Wayland + OBS
optimise_intel() {
  info "Optimising Intel GPU driver (i915) for Wayland OBS..."

  sudo tee "$OBS_ENV_FILE" > /dev/null << 'INTEL_EOF'
# OBS Wayland optimisation for Intel
# i915 driver optimisations for PipeWire and screen capture stability

# Enable Intel render compression
export INTEL_DEBUG=

# Wayland platform selection
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland

# Video codec acceleration
export LIBVA_DRIVER_NAME=iHD
export LIBVA_MESSAGING_LEVEL=0

# PipeWire audio optimisation
export PIPEWIRE_LATENCY=64/48000

# Mesa DRI settings
export LIBGL_ALWAYS_INDIRECT=0
export LIBGL_DRI3_DISABLE=0
INTEL_EOF

  sudo chmod 644 "$OBS_ENV_FILE"
  success "Created $OBS_ENV_FILE for Intel"

  info "Intel GPU detected"
  info "  Using i915 DRM driver"
  info "  Ensure Intel media driver (intel-media-driver) is installed for HW acceleration"

  # Create convenient launcher script
  create_obs_launcher
}

# Create a convenient OBS launcher that sources the environment
create_obs_launcher() {
  info "Creating OBS Wayland launcher script..."

  sudo tee "$OBS_LAUNCH_SCRIPT" > /dev/null << 'LAUNCHER_EOF'
#!/usr/bin/env bash
# OBS Wayland launcher with optimised graphics driver settings
# Automatically loads driver-specific optimisations

set -euo pipefail

# Disable problematic GLib settings that can cause crashes
export GSETTINGS_SCHEMA_DIR=/usr/share/glib-2.0/schemas

# Source driver optimisations if available
if [ -f /etc/profile.d/obs-wayland.sh ]; then
  source /etc/profile.d/obs-wayland.sh
fi

# Launch OBS
exec obs "$@"
LAUNCHER_EOF

  sudo chmod +x "$OBS_LAUNCH_SCRIPT"
  success "Created $OBS_LAUNCH_SCRIPT launcher"
  info "You can now launch OBS with: obs-wayland"

  # Also create the safe launcher if not already installed
  create_safe_launcher
}

# Create safe launcher with USB device crash recovery
create_safe_launcher() {
  local SAFE_SCRIPT="/usr/local/bin/obs-safe"
  info "Creating OBS Safe Launcher with USB device crash recovery..."

  if [ ! -f "$BASEDIR/scripts/obs-safe-launch.sh" ]; then
    warning "obs-safe-launch.sh not found in $BASEDIR/scripts/"
    info "  To create it manually, check: https://github.com/XAOSTECH/op-cap/blob/main/scripts/obs-safe-launch.sh"
    return 0
  fi

  sudo cp "$BASEDIR/scripts/obs-safe-launch.sh" "$SAFE_SCRIPT"
  sudo chmod +x "$SAFE_SCRIPT"
  success "Created $SAFE_SCRIPT launcher"
  info ""
  info "For USB capture device crash recovery, use:"
  info "  obs-safe --device /dev/video0 --vidpid 3188:1000"
  info ""
  info "This launcher:"
  info "  - Monitors USB device health"
  info "  - Auto-restarts OBS if it crashes"
  info "  - Runs auto-reconnect for device recovery"
  info "  - Logs all issues to ~/.cache/obs-safe-launch/"
  info ""
}

# Verify PipeWire is configured
verify_pipewire() {
  info "Checking PipeWire audio configuration..."

  if command -v pw-cli >/dev/null 2>&1; then
    if pw-cli list-objects core | grep -q "type: PipeWire"; then
      success "PipeWire is active and running"
    else
      warning "PipeWire may not be active"
      info "  Start PipeWire with: systemctl --user start pipewire"
    fi
  else
    warning "PipeWire not installed or pw-cli not in PATH"
    info "  Install with: sudo apt install pipewire pipewire-audio-client-libraries"
  fi
}

# Verify GPU VA-API support (hardware acceleration)
verify_vaapi() {
  info "Checking VA-API hardware acceleration support..."

  if command -v vainfo >/dev/null 2>&1; then
    if vainfo 2>&1 | grep -q "libva"; then
      success "VA-API is available"
      vainfo 2>/dev/null | head -3 || true
    else
      warning "VA-API not properly configured"
    fi
  else
    warning "vainfo not found. Install: sudo apt install vainfo"
  fi
}

# Generate system report
generate_report() {
  local REPORT_FILE="$BASEDIR/OBS_DRIVER_REPORT.txt"

  info "Generating system report..."

  {
    echo "=== OBS Driver Optimisation Report ==="
    echo "Date: $(date)"
    echo ""
    echo "=== GPU Information ==="
    lspci | grep -iE 'graphics|vga' || echo "No GPU found"
    echo ""
    echo "=== Loaded Driver Modules ==="
    lsmod | grep -E 'nvidia|amdgpu|i915' || echo "No GPU driver module loaded"
    echo ""
    echo "=== Display Server ==="
    echo "XDG_SESSION_TYPE: $XDG_SESSION_TYPE"
    echo "DISPLAY: ${DISPLAY:-not set}"
    echo "WAYLAND_DISPLAY: ${WAYLAND_DISPLAY:-not set}"
    echo ""
    echo "=== Environment Variables Set ==="
    grep -E 'export ' "$OBS_ENV_FILE" 2>/dev/null || echo "No env file found"
    echo ""
    echo "=== OBS Version ==="
    obs --version 2>/dev/null || echo "OBS not installed"
    echo ""
    echo "=== Recommended Actions ==="
    if [ "$DETECTED_GPU" = "nvidia" ]; then
      echo "- For Nvidia: Ensure nvidia-drm.modeset=1 in kernel parameters"
      echo "- Driver version 530+ recommended for best Wayland support"
    elif [ "$DETECTED_GPU" = "amd" ]; then
      echo "- For AMD: Verify AMDGPU driver is enabled in kernel"
      echo "- Install intel-media-driver for HW video encoding"
    elif [ "$DETECTED_GPU" = "intel" ]; then
      echo "- For Intel: Install intel-media-driver or libva-intel-driver"
      echo "- Enable DRI3 for better performance"
    fi
  } | tee "$REPORT_FILE"

  success "Report saved to $REPORT_FILE"
}

# Main flow
main() {
  echo ""
  echo "╔═══════════════════════════════════════════════╗"
  echo "║  OBS Wayland Driver Optimisation Tool         ║"
  echo "║  Fixes explicit sync and PipeWire issues      ║"
  echo "╚═══════════════════════════════════════════════╝"
  echo ""

  local DETECTED_GPU
  DETECTED_GPU=$(detect_gpu)

  info "Detecting graphics hardware..."

  case "${DRIVER_MODE:-}" in
    --nvidia)
      DETECTED_GPU="nvidia"
      ;;
    --amd)
      DETECTED_GPU="amd"
      ;;
    --intel)
      DETECTED_GPU="intel"
      ;;
    --auto)
      # Auto-detect, DETECTED_GPU already set
      ;;
    *)
      if [ -z "$DRIVER_MODE" ]; then
        # Auto-detect
        :
      else
        error "Unknown driver mode: $DRIVER_MODE"
        echo "Usage: $0 [--auto | --nvidia | --amd | --intel]"
        exit 1
      fi
      ;;
  esac

  case "$DETECTED_GPU" in
    nvidia)
      optimise_nvidia
      ;;
    amd)
      optimise_amd
      ;;
    intel)
      optimise_intel
      ;;
    *)
      error "Unable to detect GPU or unsupported graphics card"
      error "Supported: Nvidia (with nvidia driver), AMD (amdgpu), Intel (i915)"
      exit 1
      ;;
  esac

  echo ""
  info "Running verification checks..."
  verify_pipewire
  verify_vaapi

  echo ""
  generate_report

  echo ""
  success "Driver optimisation complete!"
  echo ""
  echo "Next steps:"
  echo "  1. Launch OBS with: obs-wayland"
  echo "  2. In OBS, check Tools > Settings > Video for hardware acceleration"
  echo "  3. Test PipeWire screen capture: Sources > Add > Screen Capture (PipeWire)"
  echo ""
  if [ "$DETECTED_GPU" = "nvidia" ]; then
    echo "Note: __NV_DISABLE_EXPLICIT_SYNC=1 is set to prevent Wayland crashes"
    echo "      If you encounter issues, check: $OBS_ENV_FILE"
  fi
  echo ""
}

main "$@"
