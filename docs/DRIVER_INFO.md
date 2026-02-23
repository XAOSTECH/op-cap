# UGREEN USB Capture Device - Official Driver Information

## Device Identification

| Property | Value |
|----------|-------|
| **Manufacturer** | Etron |
| **Device Name** | HDMI Capture |
| **USB VID:PID** | 3188:1000 (Decimal: 12680:4096) |
| **Driver Version** | 1.0.15.12 |
| **Driver Date** | 07/20/2020 |
| **Driver Type** | UVC (USB Video Class) Lower Filter |

## Device Detection

```bash
# List all connected UGREEN devices
lsusb | grep -i ugreen

# Expected output:
# Bus XXX Device YYY: ID 3188:1000 ITE UGREEN 25173
```

## Linux Support

This is a **standard UVC (USB Video Class)** device:
- ✅ Fully supported by Linux kernel v4l2 driver
- ✅ Works with libv4l2 and FFmpeg
- ✅ Compatible with OBS on Linux
- ✅ No proprietary Linux driver needed

The Windows driver (uvclower.sys) is a UVC **lower filter** that adds vendor-specific enhancements, but the core functionality is standard UVC.

## Official Driver Details

**Source:** `driver/Build.0.15.12/Drivers/uvclower.inf`

**Platform Support:**
- Windows x86 (32-bit): `x86/uvclower.sys`
- Windows x64 (64-bit): `x64/uvclower.sys`
- Catalog: `uvclower.cat`

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
- **Color Spaces**: 
  - YUV 4:2:0 (NV12, YU12) - Standard 8-bit
  - **P010** (10-bit HDR) - Native 10-bit format support
- **Max Resolution**: 4K UHD (3840x2160)
- **Max Framerate**: Up to 60 fps (hardware dependent)
- **HDR Support**: ✅ Full HDR10 / Rec.2100 PQ capable

### USB Controller
- **Chip Vendor**: Etron (indicated by VID 3188)
- **USB Speed**: USB 3.0 / USB 3.1
- **Interface Type**: USB Video Class (UVC)

## Optimization for Linux

### v4l2-ctl Device Information

```bash
# Get detailed device info
v4l2-ctl -d /dev/video0 --all

# List pixel formats (includes P010 if kernel patched)
v4l2-ctl -d /dev/video0 --list-formats-ext

# Check controls
v4l2-ctl -d /dev/video0 --list-ctrls

# Verify P010 support (if present, kernel is patched)
v4l2-ctl -d /dev/video0 --list-formats-ext | grep -i p010
```

### P010 HDR Format Support

**Status**: ⚠️ Requires Linux kernel patch (v4l2 P010 support)

The UGREEN 25173 natively supports P010 (10-bit YUV 4:2:0) for HDR capture, but standard Linux kernels do not expose this format via v4l2. A kernel patch is required:

**Pre-patched OS Options:**
- Raspberry Pi OS aarch64 with P010 support: https://github.com/awawa-dev/P010_for_V4L2/releases
- Includes patched uvc driver for v4l2 P010 recognition

**Manual Patching:**
- Apply patches from: https://github.com/awawa-dev/P010_for_V4L2
- Recompile kernel with P010 v4l2 support
- See [P010 Kernel Patches](../../../P010_for_V4L2) (submodule at workspace root)

#### P010 vs NV12 Quality Comparison

| Aspect | NV12 (8-bit) | P010 (10-bit) |
|--------|--------------|---------------|
| Bit Depth | 8-bit | 10-bit |
| Luminance Range | 16-144 (0-255 scale) | 64-576 (0-1023 scale) |
| Detail Levels | 128 | 512 |
| HDR Accuracy | ~2x loss when encoded | Native 4K detail |
| Quantization Artifacts | Visible in dark scenes | Minimal |
| File Size | Smaller | ~25% larger |
| Encoder Conversion | NVENC 8→10-bit | Direct pass-through |
| YouTube Stream | Acceptable HDR | Optimal HDR |

#### Brightness Accuracy (Test Data)

Source brightness: 200 nits (test reference)

| Device | Output | Accuracy | Notes |
|--------|--------|----------|-------|
| **UGREEN 25173** | 205 nits | ✅ +2.5% | Best in class, minimal distortion |
| Elgato HD60X | 251 nits | ⚠️ +25% | Whites inverted under 150% scaling |
| Hagibis THB05 | 255 nits | ❌ +27.5% | Firmware bugs, unsupported |

UGREEN is the **most accurate** USB HDR capture device tested.

### Recommended v4l2 Settings

Based on the official driver specifications:

```bash
# Optimal capture resolution and framerate
Video Resolution: 3840x2160 (4K)
Framerate: 30 fps (stable)
Pixel Format: YU12 (Planar YUV 4:2:0)
Color Space: Rec.709 / BT.709

# Alternative (lower resource)
Video Resolution: 1920x1080 (Full HD)
Framerate: 60 fps
Pixel Format: YUYV (Packed YUV 4:2:2)
```

### FFmpeg Integration

```bash
# Test capture with FFmpeg
ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 -framerate 30 -i /dev/video0 -t 10 test.mp4

# 4K capture
ffmpeg -f v4l2 -input_format yuv420p -video_size 3840x2160 -framerate 30 -i /dev/video0 -t 10 test.mp4
```

## Linux Driver Detection

The device is detected by:

1. **libusb** (User-space):
   - VID: 0x3188
   - PID: 0x1000

2. **uvcvideo kernel module**:
   - Automatically loads on device connection
   - Creates /dev/videoX nodes

3. **v4l2 framework**:
   - Provides standardized API
   - Supports hardware acceleration (if available)

## Stability Tips for Linux

### USB Configuration

```bash
# Disable USB autosuspend (prevents disconnections)
echo -1 | sudo tee /sys/bus/usb/devices/*/power/autosuspend_delay_ms

# Check device bus power
cat /sys/bus/usb/devices/*/power/control
```

### v4l2loopback for Stability

Use the op-cap auto-reconnect system to isolate OBS from hardware:

```bash
# Start FFmpeg feed to virtual device
systemctl start usb-capture-ffmpeg.service

# OBS reads from /dev/video10 (never directly from USB)
# Auto-reconnect handles device recovery
```

### Hardware Issues (UGREEN Specifically)

The UGREEN device is known for:
- ✅ Excellent video quality (4K HDR capable)
- ⚠️  Loose USB-C connector on some units
- ⚠️  Sensitivity to USB power delivery

**If experiencing crashes:**
1. Check motherboard USB-C power delivery (BIOS settings)
2. Use high-quality USB 3.0+ cable
3. Try different USB port
4. Use `obs-safe` launcher with auto-recovery
5. Enable v4l2loopback isolation

## UGREEN Feature Reference

Common UGREEN models with uvclower driver:

| Model | VID:PID | Features |
|-------|---------|----------|
| UGREEN 25173 | 3188:1000 | HDMI to USB 3.0, 4K@30Hz, HDR |
| UGREEN 70403 | 3188:1000 | Same as 25173 |

## P010 Kernel Patches & Resources

### Credit: @awawa-dev (HyperHDR Project)

The P010 v4l2 support patches and prebuilt kernels are maintained by Alexander Weissmann (@awawa-dev), creator of HyperHDR. His work includes:

- **P010_for_V4L2**: Linux kernel patches for P010 UVC support
- **HyperHDR**: Comprehensive HDR capture and processing software
- **Testing & Validation**: Extensive device testing (UGREEN 25173, Elgato HD60X, Hagibis THB05)

**Repository**: https://github.com/awawa-dev/P010_for_V4L2

**Discussion (Full HDR Implementation Details)**: https://github.com/awawa-dev/HyperHDR/discussions/967

---

## References

- **UVC Specification**: https://www.usb.org/uvc
- **Linux v4l2 Documentation**: https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/v4l2.html
- **ffmpeg v4l2**: https://ffmpeg.org/ffmpeg-devices.html#video4linux2,-v4l2
- **OBS on Linux**: https://obsproject.com/
- **Linux Kernel - Media Subsystem**: https://www.kernel.org/doc/html/latest/media/index.html

## File Locations

- **Driver Source**: [Build.0.15.12](https://www.mediafire.com/file/41l9pmpp2wqn6ks/25173+Build.0.15.12.zip/file)
- **P010 Kernel Patches**: [P010_for_V4L2 (workspace root)](../../../P010_for_V4L2)
- **Linux Optimization**: [WAYLAND_OPTIMISATION.md](WAYLAND_OPTIMISATION.md)
- **Buffer Troubleshooting**: [BUFFER_CORRUPTION.md](BUFFER_CORRUPTION.md)
- **Safe Launcher**: [scripts/obs-safe-launch.sh](../scripts/obs-safe-launch.sh)

---

*Generated from official driver: uvclower.inf v1.0.15.12*
