#!/usr/bin/env bash
# Quick reference for op-cap troubleshooting commands
# Copy-paste these commands for rapid diagnosis

# ===========================================
# BUFFER CORRUPTION DIAGNOSIS
# ===========================================

# 1. Validate capture quality (finds corruption immediately)
make validate-capture DEVICE=/dev/video0

# 2. Check USB device info
lsusb | grep -i "your-device-name"
# Example: ID 3188:1000 ITE UGREEN 25173

# 3. Monitor FFmpeg service for corruption messages
sudo journalctl -u usb-capture-ffmpeg.service -f | grep -i "corrupt\|timeout"

# 4. Check captured frame size (should match resolution)
# For 3840x2160 NV12: 3840 * 2160 * 1.5 = 12,441,600 bytes/frame
ffmpeg -f v4l2 -video_size 3840x2160 -framerate 30 -i /dev/video0 -t 1 -f rawvideo /tmp/test.raw 2>&1 | grep -i "corrupt"
ls -lh /tmp/test.raw  # Check size

# ===========================================
# USB POWER MANAGEMENT
# ===========================================

# Check autosuspend status (should be "on" if optimised)
cat /sys/bus/usb/devices/*/power/control | sort -u

# Disable autosuspend for your device
make optimise-device VIDPID=3188:1000

# Verify autosuspend is disabled
grep -r "power/control" /sys/bus/usb/devices/*/power/control | grep on

# ===========================================
# RESOLUTION TESTING
# ===========================================

# Test at 4K
ffmpeg -f v4l2 -video_size 3840x2160 -framerate 30 -i /dev/video0 -t 5 -f null - 2>&1 | grep -iE "corrupt|timeout" | wc -l

# Test at 1080p
ffmpeg -f v4l2 -video_size 1920x1080 -framerate 30 -i /dev/video0 -t 5 -f null - 2>&1 | grep -iE "corrupt|timeout" | wc -l

# Change service resolution
sudo nano /etc/default/usb-capture
# Edit: USB_CAPTURE_RES=1920x1080
sudo systemctl restart usb-capture-ffmpeg.service

# ===========================================
# SERVICE MONITORING
# ===========================================

# Check service status
sudo systemctl status usb-capture-ffmpeg.service usb-capture-monitor.service

# View service logs (last 50 lines)
sudo journalctl -u usb-capture-ffmpeg.service -n 50

# Stream logs in real-time (Ctrl+C to exit)
sudo journalctl -u usb-capture-ffmpeg.service -f

# Count total corrupted frames since last restart
sudo journalctl -u usb-capture-ffmpeg.service | grep -i "corrupted" | wc -l

# ===========================================
# DEVICE DETECTION & RESET
# ===========================================

# List all video devices
ls -la /dev/video*

# Find USB device by name
lsusb | grep -i "ugreen\|capture\|camera"

# Safely disable USB device (unbind)
echo "2-1" | sudo tee /sys/bus/usb/devices/usb2/unbind

# Safely re-enable USB device (bind)
echo "2-1" | sudo tee /sys/bus/usb/devices/usb2/bind

# Full USB reset
sudo ./scripts/usb_reset.sh 3188:1000

# ===========================================
# KERNEL & SYSTEM INFO
# ===========================================

# Check kernel USB errors
dmesg | grep -iE "usb.*error|xhci.*error" | tail -20

# Check USB bus speed
lsusb -v -d 3188:1000 2>/dev/null | grep -i "speed\|bcdUSB"

# Show USB device power info
cat /sys/bus/usb/devices/3-1/power/control  # Replace 3-1 with your device

# ===========================================
# FFMPEG COMMAND TEMPLATES
# ===========================================

# Capture with verbose logging (see all warnings/errors)
ffmpeg -hide_banner -loglevel debug -f v4l2 -video_size 3840x2160 -framerate 30 -i /dev/video0 -t 10 -f null - 2>&1 | tee /tmp/ffmpeg_debug.log

# Test if loopback is receiving data
ffmpeg -f v4l2 -i /dev/video10 -t 5 -f null - 2>&1 | grep -E "fps|frame"

# Feed test pattern (no source needed)
ffmpeg -f lavfi -i testsrc=size=3840x2160:duration=60 -f v4l2 /dev/video0 &
sleep 2 && make validate-capture DEVICE=/dev/video0
pkill ffmpeg

# ===========================================
# QUICK FIXES (copy-paste)
# ===========================================

# Fix 1: Disable autosuspend + restart service
sudo ./scripts/optimise_device.sh 3188:1000 && sudo systemctl restart usb-capture-ffmpeg.service

# Fix 2: Switch to 1080p
sudo bash -c 'echo "USB_CAPTURE_RES=1920x1080" >> /etc/default/usb-capture' && sudo systemctl restart usb-capture-ffmpeg.service

# Fix 3: Check loopback is working
v4l2-ctl --list-devices | grep -i "USB_Capture_Loop"

# Fix 4: Re-create loopback if missing
sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback video_nr=10 card_label="USB_Capture_Loop" exclusive_caps=1

# ===========================================
# DIAGNOSTIC BUNDLE (collect all info for support)
# ===========================================

collect_diagnostics() {
  echo "Collecting diagnostics..."
  mkdir -p /tmp/op-cap-diag
  journalctl -u usb-capture-ffmpeg.service -n 200 > /tmp/op-cap-diag/ffmpeg.log
  dmesg | tail -100 > /tmp/op-cap-diag/dmesg.log
  lsusb -vvv > /tmp/op-cap-diag/lsusb.log
  cat /etc/default/usb-capture > /tmp/op-cap-diag/usb-capture.conf
  uname -a > /tmp/op-cap-diag/uname.log
  ffmpeg -version > /tmp/op-cap-diag/ffmpeg_version.log
  tar czf /tmp/op-cap-diagnostics.tar.gz -C /tmp op-cap-diag
  echo "Diagnostics saved to: /tmp/op-cap-diagnostics.tar.gz"
  echo "Compressed size: $(du -h /tmp/op-cap-diagnostics.tar.gz | cut -f1)"
}

collect_diagnostics
