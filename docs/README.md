# op-cap — Linux USB Capture Card Optimisation

Stabilise high-throughput USB capture devices for OBS on Linux. Provides auto-reconnect, USB reset, v4l2loopback feed isolation, and performance optimisations.

## Features

- **v4l2loopback isolation** — FFmpeg feeds capture to `/dev/video10`, preventing OBS crashes from driver issues
- **Auto-reconnect** — Monitors device and restarts feed on disconnect
- **USB reset & driver rebind** — Recovers from device hangs without reboot
- **Performance optimisations** — Disables USB autosuspend, optimises power settings
- **HDR passthrough** — Configurable color handling modes
- **Optional overlay** — Add logo/watermark from URL or file
- **Format auto-detection** — Detects best resolution/fps during install
- **Wayland graphics optimisation** — Fixes OBS crashes on Wayland with explicit sync and PipeWire support

## Quick Start

```bash
make build
make install   # Interactive — select your capture device
```

Optimise graphics drivers for OBS on Wayland (fixes explicit sync and PipeWire issues):
```bash
make optimise-drivers   # Auto-detect and optimise GPU driver
```

Or install with driver optimisation in one step:
```bash
make install-with-drivers
```

Check status:
```bash
sudo systemctl status usb-capture-ffmpeg.service usb-capture-monitor.service
```

Uninstall:
```bash
make uninstall
```

## Maintenance & Recovery System

A comprehensive interactive maintenance system is available for troubleshooting and recovery:

```bash
# Launch interactive maintenance menu
sudo ./scripts/maintenance.sh
```

This menu provides access to 9 specialized recovery tools:

| Tool | Description | Use When |
|------|-------------|----------|
| **detect_device** | Enumerate USB video devices | Device not found or caps unclear |
| **disable_overlay** | Remove on-screen logos/OSD | Capture has unwanted watermarks |
| **hard_reset** | Unbind/rebind USB driver | Device unresponsive but enumerated |
| **optimise_device** | Disable autosuspend, optimize power | Timeouts, USB power errors |
| **pick_delogo** | Visually select logo region | Need to identify overlay position |
| **repair** | Full recovery workflow | Device broken, try complete reset |
| **simulate_disconnect** | Test device authority toggle | Testing/diagnostics only |
| **uhubctl_reset** | Power cycle USB hub port | Device needs complete electrical reset |
| **usb_reset** | Reset device via ioctl | Temporary access to broken device |

**Key features:**
- ✅ Auto-detects USB capture devices
- ✅ Collects arguments based on tool requirements
- ✅ Add new tools by dropping scripts in `scripts/maintenance/`

## Quick Troubleshooting Commands

**Buffer corruption detected?** Run this immediately:
```bash
make validate-capture DEVICE=/dev/video0
# Reports corruption count and recommends resolution (4K vs 1080p)
```

**Autosuspend causing timeouts?**
```bash
make optimise-device VIDPID=3188:1000  # Find VID:PID with 'lsusb'
```

**Device completely broken?**
```bash
sudo ./scripts/maintenance.sh
# Select option 6 (repair) for full recovery workflow
```

**View real-time FFmpeg logs:**
```bash
sudo journalctl -u usb-capture-ffmpeg.service -f
```

**For all troubleshooting commands, see `scripts/quick_reference.sh`:**
```bash
bash scripts/quick_reference.sh | head -50  # Print cheat sheet
```

For detailed buffer corruption diagnosis, see **[BUFFER_CORRUPTION.md](BUFFER_CORRUPTION.md)**.

## Scripts Reference

### Core Scripts

| Script | Purpose |
|--------|---------|
| [`install.sh`](../scripts/install.sh) | Interactive setup: detect device, install services, v4l2loopback |
| [`validate_capture.sh`](../scripts/validate_capture.sh) | Test device for corruption, timeouts, USB power issues |
| [`optimise_device.sh`](../scripts/optimise_device.sh) | Disable autosuspend, optimize USB power for device |
| [`optimise_drivers.sh`](../scripts/optimise_drivers.sh) | Fix OBS Wayland crashes (Nvidia/AMD/Intel) |
| [`auto_reconnect.sh`](../scripts/auto_reconnect.sh) | Monitor device, auto-restart on disconnect |
| [`parse_formats.sh`](../scripts/parse_formats.sh) | Auto-detect best resolution/fps from device |
| [`quick_reference.sh`](../scripts/quick_reference.sh) | Troubleshooting command cheat sheet |

### Maintenance Tools

See **Maintenance & Recovery System** section above for the 9 interactive recovery tools in [`scripts/maintenance/`](../scripts/maintenance/)

## Configuration

All settings in `/etc/default/usb-capture`:

| Variable | Description | Default |
|----------|-------------|---------|
| `USB_CAPTURE_VIDEO` | Device path (auto-detected) | `/dev/v4l/by-id/...` |
| `USB_CAPTURE_RES` | Resolution | `3840x2160` |
| `USB_CAPTURE_FPS` | Framerate | `30` |
| `USB_CAPTURE_FORMAT` | Input format | `NV12` |
| `USB_CAPTURE_HDR_MODE` | HDR handling (see below) | `2` |
| `USB_CAPTURE_OVERLAY_URL` | Overlay image URL | *(empty)* |
| `USB_CAPTURE_OVERLAY_FILE` | Overlay image path | *(empty)* |
| `USB_CAPTURE_OVERLAY_X/Y` | Overlay position | `10` |
| `USB_CAPTURE_OVERLAY_SCALE` | Overlay width (px) | `500` |
| `USB_CAPTURE_DELOGO_ENABLE` | Enable delogo filter | `0` |
| `USB_CAPTURE_VALIDATE_BUFFERS` | Detect corrupted frames | `1` |
| `USB_CAPTURE_CORRUPT_THRESHOLD` | Frames before fallback | `5` |
| `USB_CAPTURE_FALLBACK_RES` | Fallback resolution | `1920x1080` |

### HDR Modes

| Mode | Behavior |
|------|----------|
| `0` | Auto — trust device (may delay startup) |
| `1` | Force HDR interpretation + tonemap to SDR |
| `2` | Force HDR passthrough (fastest startup) **← default** |
| `3` | Force SDR interpretation |

Most devices auto-handle HDR internally. Mode 2 provides fastest startup without color issues.

## OBS Setup

1. Add **Video Capture Device** source
2. Select `/dev/video10` (labeled "USB_Capture_Loop")
3. Resolution/FPS auto-detected

If device not visible:
```bash
sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback video_nr=10 card_label="USB_Capture_Loop" exclusive_caps=1
```

### Troubleshooting OBS Connection

- **Loopback device not created:** See above modprobe command
- **Device disconnects under load:** Run `sudo ./scripts/maintenance.sh` → select repair (option 6)
- **Auto-reconnect not working:** Check `journalctl -u usb-capture-monitor.service -f` for errors
- **HW acceleration crashes on Wayland:** Run `make optimise-drivers` to fix GPU driver issues

## Troubleshooting

### OBS-Related Issues

- **Loopback device not created:** Run `sudo modprobe v4l2loopback video_nr=10 exclusive_caps=1` and restart OBS
- **Device disconnects under load:** Run `sudo ./scripts/maintenance.sh` → select option 6 (repair)
- **Auto-reconnect not working:** Check logs with `journalctl -u usb-capture-monitor.service -f`
- **HW acceleration crashes on Wayland:** Run `make optimise-drivers` to fix GPU driver issues (see Wayland section below)

### Service Debugging

**View real-time FFmpeg logs:**
```bash
journalctl -u usb-capture-ffmpeg.service -f
```

**Check USB errors:**
```bash
dmesg | grep -iE 'usb|xhci' | tail -20
```

**Verify autosuspend is disabled:**
```bash
cat /sys/bus/usb/devices/*/power/control
```

### Device Discovery & Diagnostics

**Detect all USB video devices:**
```bash
./scripts/detect_device.sh
# Or manually: lsusb | grep -iE 'video|capture|camera'
```

**Get device capabilities:**
```bash
v4l2-ctl -d /dev/video0 --all
```

**Test capture directly:**
```bash
ffmpeg -f v4l2 -i /dev/video0 -t 10 -f null -
```

## Wayland Troubleshooting

**For comprehensive setup and advanced configuration, see [WAYLAND_OPTIMISATION.md](WAYLAND_OPTIMISATION.md).**

OBS on Wayland can crash due to explicit sync issues with certain GPU drivers. If you experience crashes:

### Nvidia GPU

**Symptoms:** Crashes when opening projectors, screen capture with PipeWire, or during streaming.

**Fix:**
```bash
sudo ./scripts/optimise_drivers.sh --nvidia
```

This sets `__NV_DISABLE_EXPLICIT_SYNC=1` which disables the problematic explicit sync protocol.

**Additional kernel parameter recommended:**
Add `nvidia-drm.modeset=1` to your kernel boot parameters:
1. Edit `/etc/default/grub`
2. Add to `GRUB_CMDLINE_LINUX_DEFAULT`: `nvidia-drm.modeset=1`
3. Run: `sudo update-grub`
4. Reboot

**Driver version:** Use driver 530+ for best Wayland support.
```bash
nvidia-smi  # Check current version
# If older than 530, update: sudo apt install nvidia-driver-latest-dkms
```

### AMD GPU

**Symptoms:** Screen capture hangs or stuttering with PipeWire.

**Fix:**
```bash
sudo ./scripts/optimise_drivers.sh --amd
```

Ensures AMDGPU driver is optimised for Wayland, enables color block compression.

### Intel GPU

**Symptoms:** PipeWire screen capture issues or poor performance.

**Fix:**
```bash
sudo ./scripts/optimise_drivers.sh --intel
```

Optimises i915 driver for VA-API hardware acceleration on Wayland.

### Verify PipeWire Configuration

After running driver optimisation:
```bash
# Check if PipeWire is running
systemctl --user status pipewire

# Start if not running
systemctl --user start pipewire

# Test audio routing
pw-play /usr/share/sounds/freedesktop/stereo/complete.oga
```

### Launch OBS with Optimised Settings

Use the provided launcher script:
```bash
obs-wayland    # Automatically sources optimised driver settings
```

Or manually source the environment:
```bash
source /etc/profile.d/obs-wayland.sh
obs
```

### Check Optimisation Report

After running `optimise_drivers.sh`, check the generated report:
```bash
cat $PWD/OBS_DRIVER_REPORT.txt
```

This shows GPU info, loaded drivers, environment variables, and recommended actions.

## USB Device Troubleshooting

### Buffer Corruption Issues

If FFmpeg logs show repeated `Dequeued v4l2 buffer contains corrupted data` or `select timed out` errors, your capture card is sending malformed frames. This is a **hardware/firmware issue**, not software.

**Symptoms:**
```
[video4linux2,v4l2] Dequeued v4l2 buffer contains corrupted data (16372 bytes)
error: v4l2-input: select timed out
error: v4l2-input: failed to log status
```

**Quick diagnosis:**

1. **Does your capture card display "No Connection"?** → Connect an HDMI source
2. **Run validation test:**
   ```bash
   make validate-capture DEVICE=/dev/video0
   ```
3. **See corruption only at 4K?** → Use 1920x1080 instead (`USB_CAPTURE_RES=1920x1080`)
4. **Autosuspend enabled?** → Run `make optimise-device VIDPID=3188:1000`

**For detailed troubleshooting, see [BUFFER_CORRUPTION.md](BUFFER_CORRUPTION.md).**

### How v4l2loopback Enables Auto-Recovery

v4l2loopback creates a virtual video device (`/dev/video10`) that **decouples the physical capture device from OBS**:

1. **FFmpeg process** reads from your USB device and writes to loopback continuously
2. **OBS reads** from the stable loopback device (not the problematic hardware)
3. **Auto-reconnect monitor** watches both and restarts if the USB device disconnects
4. **Isolated failures**: If hardware hangs, only FFmpeg crashes (and auto-restarts), OBS continues unaffected

**Result:** OBS never directly touches unreliable hardware—it reads from a stable intermediate buffer.

### Advanced USB Device Management

#### Making USB Optimisations Persistent with udev Rules

After running `optimise_device.sh`, USB optimisations (autosuspend disable, power settings) are applied **but lost on reboot**. Make them persistent:

**1. Identify your device:**
```bash
lsusb
# Output: Bus 002 Device 004: ID 3188:1000 Manufacture Name
# VID:PID is 3188:1000
```

**2. Create persistent udev rule:**
```bash
sudo nano /etc/udev/rules.d/99-usb-capture-optimisation.rules
```

Add the rule (customize VID:PID for your device):
```udev
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="3188", ATTR{idProduct}=="1000", ATTR{power/control}="on", ATTR{power/autosuspend_delay_ms}="-1"
```

**3. Reload rules:**
```bash
sudo udevadm control --reload-rules && sudo udevadm trigger
```

#### Disabling USB Device Without Unplugging

Safely disable your USB capture device when not in use (prevents phantom timeouts):

```bash
# Find device bus:port
lsusb | grep your-device
# Output: Bus 002 Device 004 => bus:port is 2-1

# Disable (unbind from USB)
echo "2-1" | sudo tee /sys/bus/usb/devices/usb2/unbind

# Re-enable (bind to USB)
echo "2-1" | sudo tee /sys/bus/usb/devices/usb2/bind

# Verify status
lsusb | grep your-device && echo "Enabled" || echo "Disabled"
```

## Advanced Usage

### Multiple Capture Devices

If you use multiple physical capture devices, run multiple FFmpeg feeds to separate v4l2loopback devices:

```bash
# Device 1: /dev/video0 → /dev/video10
# Device 2: /dev/video1 → /dev/video11
# Device 3: /dev/video2 → /dev/video12

# Pre-configure loopback devices using kernel module parameters:
sudo modprobe v4l2loopback \
  video_nr=10,11,12 \
  card_label="USB_Capture_1","USB_Capture_2","USB_Capture_3" \
  exclusive_caps=1

# Then run separate FFmpeg instances for each device
```

### Custom Overlay Removal

If your device has an on-screen logo that can't be removed via UVC controls, use FFmpeg filters:

**Delogo filter (removes solid logos):**
```bash
# Tune x, y, w, h to your logo position/size
ffmpeg -f v4l2 -i /dev/video0 \
  -vf "delogo=x=3500:y=20:w=300:h=100:show=0" \
  -f v4l2loopback /dev/video10
```

**Crop filter (removes border areas):**
```bash
# Remove top-right area: crop=width:height:x_offset:y_offset
ffmpeg -f v4l2 -i /dev/video0 \
  -vf "crop=3840:2120:0:0" \
  -f v4l2loopback /dev/video10
```

### Why Use v4l2loopback Instead of Direct Capture

Never capture the physical USB device directly in OBS. Always use the v4l2loopback bridge:

**Why:**
- **Isolation**: If the hardware hangs, only FFmpeg crashes (and auto-restarts), OBS continues
- **Stability**: OBS doesn't touch unreliable hardware directly
- **Auto-recovery**: Automatic reconnection on device disconnect
- **Compatibility**: Works with all capture devices, eliminates driver-specific crashes

**What happens with direct capture:**
```
Device hangs → Kernel driver hang → OBS freezes → Requires restart
```

**What happens with v4l2loopback:**
```
Device hangs → FFmpeg exits → Auto-restart service → OBS reconnects in seconds
```

## Requirements

- `ffmpeg`, `v4l-utils`, `v4l2loopback-dkms`
- Optional: `uhubctl` (hub power control), `slop` (visual picker)
- For Nvidia: `nvidia-driver` 530+ recommended
- For GPU HW acceleration: `vainfo`, `libva-driver-*` (driver-specific)

```bash
sudo apt install ffmpeg v4l-utils v4l2loopback-dkms vainfo
```

For hardware video encoding on Nvidia:
```bash
sudo apt install nvidia-driver-latest-dkms
```

For AMD GPU:
```bash
sudo apt install mesa-vdpau-drivers libvdpau-va-gl libva-amd64-linux
```

For Intel GPU:
```bash
sudo apt install intel-media-driver libva-intel-driver
```
