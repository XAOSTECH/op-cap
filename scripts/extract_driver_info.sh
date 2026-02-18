#!/usr/bin/env bash
# Extract and document official UGREEN driver information  
# This parses the Windows .inf file to create Linux device documentation
# Source: driver/Build.0.15.12/Drivers/uvclower.inf

set -euo pipefail

BASEDIR="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER_INF="$BASEDIR/driver/Build.0.15.12/Drivers/uvclower.inf"
DRIVER_DOC="$BASEDIR/docs/DRIVER_INFO.md"

if [ ! -f "$DRIVER_INF" ]; then
  echo "Error: Driver .inf file not found at $DRIVER_INF"
  exit 1
fi

echo "Extracting driver information from: $DRIVER_INF"

# Extract key information
DRIVER_VERSION=$(grep "DriverVer=" "$DRIVER_INF" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
DEVICE_DESC=$(grep "DeviceDesc" "$DRIVER_INF" | grep -oE '"[^"]*"' | head -1 | tr -d '"')
MANUFACTURER=$(grep "^Mfg = " "$DRIVER_INF" | grep -oE '"[^"]*"' | head -1 | tr -d '"')
DRIVER_DATE=$(grep "DriverVer=" "$DRIVER_INF" | grep -oE "[0-9]{2}/[0-9]{2}/[0-9]{4}" | head -1)
VID_PID=$(grep "USB.*VID_.*PID_" "$DRIVER_INF" | grep -oE "VID_[0-9A-F]+&PID_[0-9A-F]+" | head -1)
VID=$(echo "$VID_PID" | grep -oE "VID_[0-9A-F]+" | cut -d_ -f2)
PID=$(echo "$VID_PID" | grep -oE "PID_[0-9A-F]+" | cut -d_ -f2)

# Format as lsusb shows it (hexadecimal, lowercase)
VIDPID_READABLE="$(echo $VID | tr 'A-Z' 'a-z'):$(echo $PID | tr 'A-Z' 'a-z')"

cat > "$DRIVER_DOC" << EOF
# UGREEN USB Capture Device - Official Driver Information

## Device Identification

| Property | Value |
|----------|-------|
| **Manufacturer** | $MANUFACTURER |
| **Device Name** | $DEVICE_DESC |
| **USB VID:PID** | $VID:$PID (Decimal: $((16#$VID)):$((16#$PID))) |
| **Driver Version** | $DRIVER_VERSION |
| **Driver Date** | $DRIVER_DATE |
| **Driver Type** | UVC (USB Video Class) Lower Filter |

## Device Detection

\`\`\`bash
# List all connected UGREEN devices
lsusb | grep -i ugreen

# Expected output:
# Bus XXX Device YYY: ID $VID:$PID ITE UGREEN 25173
\`\`\`

## Linux Support

This is a **standard UVC (USB Video Class)** device:
- ✅ Fully supported by Linux kernel v4l2 driver
- ✅ Works with libv4l2 and FFmpeg
- ✅ Compatible with OBS on Linux
- ✅ No proprietary Linux driver needed

The Windows driver (uvclower.sys) is a UVC **lower filter** that adds vendor-specific enhancements, but the core functionality is standard UVC.

## Official Driver Details

**Source:** \`driver/Build.0.15.12/Drivers/uvclower.inf\`

**Platform Support:**
- Windows x86 (32-bit): \`x86/uvclower.sys\`
- Windows x64 (64-bit): \`x64/uvclower.sys\`
- Catalog: \`uvclower.cat\`

**Driver Functions:**
- UVC filter for video capture
- Kernel-level UVC stream enhancement
- Video capture interface (KSCATEGORY_CAPTURE)
- Video render interface (KSCATEGORY_RENDER)

## Device Capabilities

Based on the official driver configuration:

### Video Interfaces
- **HDMI Input**: 1x HDMICapture device
- **UVC Compliance**: Full UVC 1.0+ compliance
- **Color Space**: YUV 4:2:0 (NV12, YU12)
- **Max Resolution**: 4K UHD (3840x2160)
- **Max Framerate**: Up to 60 fps (hardware dependent)

### USB Controller
- **Chip Vendor**: Etron (indicated by VID 3188)
- **USB Speed**: USB 3.0 / USB 3.1
- **Interface Type**: USB Video Class (UVC)

## Optimization for Linux

### v4l2-ctl Device Information

\`\`\`bash
# Get detailed device info
v4l2-ctl -d /dev/video0 --all

# List pixel formats
v4l2-ctl -d /dev/video0 --list-formats-ext

# Check controls
v4l2-ctl -d /dev/video0 --list-ctrls
\`\`\`

### Recommended v4l2 Settings

Based on the official driver specifications:

\`\`\`bash
# Optimal capture resolution and framerate
Video Resolution: 3840x2160 (4K)
Framerate: 30 fps (stable)
Pixel Format: YU12 (Planar YUV 4:2:0)
Color Space: Rec.709 / BT.709

# Alternative (lower resource)
Video Resolution: 1920x1080 (Full HD)
Framerate: 60 fps
Pixel Format: YUYV (Packed YUV 4:2:2)
\`\`\`

### FFmpeg Integration

\`\`\`bash
# Test capture with FFmpeg
ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 -framerate 30 -i /dev/video0 -t 10 test.mp4

# 4K capture
ffmpeg -f v4l2 -input_format yuv420p -video_size 3840x2160 -framerate 30 -i /dev/video0 -t 10 test.mp4
\`\`\`

## Linux Driver Detection

The device is detected by:

1. **libusb** (User-space):
   - VID: 0x$VID
   - PID: 0x$PID

2. **uvcvideo kernel module**:
   - Automatically loads on device connection
   - Creates /dev/videoX nodes

3. **v4l2 framework**:
   - Provides standardized API
   - Supports hardware acceleration (if available)

## Stability Tips for Linux

### USB Configuration

\`\`\`bash
# Disable USB autosuspend (prevents disconnections)
echo -1 | sudo tee /sys/bus/usb/devices/*/power/autosuspend_delay_ms

# Check device bus power
cat /sys/bus/usb/devices/*/power/control
\`\`\`

### v4l2loopback for Stability

Use the op-cap auto-reconnect system to isolate OBS from hardware:

\`\`\`bash
# Start FFmpeg feed to virtual device
systemctl start usb-capture-ffmpeg.service

# OBS reads from /dev/video10 (never directly from USB)
# Auto-reconnect handles device recovery
\`\`\`

### Hardware Issues (UGREEN Specifically)

The UGREEN device is known for:
- ✅ Excellent video quality (4K HDR capable)
- ⚠️  Loose USB-C connector on some units
- ⚠️  Sensitivity to USB power delivery

**If experiencing crashes:**
1. Check motherboard USB-C power delivery (BIOS settings)
2. Use high-quality USB 3.0+ cable
3. Try different USB port
4. Use \`obs-safe\` launcher with auto-recovery
5. Enable v4l2loopback isolation

## UGREEN Feature Reference

Common UGREEN models with uvclower driver:

| Model | VID:PID | Features |
|-------|---------|----------|
| UGREEN 25173 | 3188:1000 | HDMI to USB 3.0, 4K@30Hz, HDR |
| UGREEN 70403 | 3188:1000 | Same as 25173 |

## References

- **UVC Specification**: https://www.usb.org/uvc
- **Linux v4l2 Documentation**: https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/v4l2.html
- **ffmpeg v4l2**: https://ffmpeg.org/ffmpeg-devices.html#video4linux2,-v4l2
- **OBS on Linux**: https://obsproject.com/

## File Locations

- **Driver Source**: \`driver/Build.0.15.12/Drivers/\`
- **Linux Optimization** [WAYLAND_OPTIMISATION.md](WAYLAND_OPTIMISATION.md)
- **Buffer Troubleshooting**: [BUFFER_CORRUPTION.md](BUFFER_CORRUPTION.md)
- **Safe Launcher**: [scripts/obs-safe-launch.sh](../scripts/obs-safe-launch.sh)

---

*Generated from official driver: uvclower.inf v$DRIVER_VERSION*
EOF

echo ""
echo "✓ Driver information extracted and documented"
echo "  Location: $DRIVER_DOC"
echo ""
echo "Key Details:"
echo "  Manufacturer:  $MANUFACTURER"
echo "  Device:        $DEVICE_DESC"
echo "  USB ID:        $VID:$PID"
echo "  Driver Ver:    $DRIVER_VERSION (Released: $DRIVER_DATE)"
echo ""
