# USB Capture Card Buffer Corruption Troubleshooting

This guide addresses persistent buffer corruption errors when using USB capture devices with v4l2loopback and OBS on Linux.

## Symptom Recognition

### Corrupted Frame Messages (Most Common)

```
[video4linux2,v4l2 @ ...] Dequeued v4l2 buffer contains corrupted data (16372 bytes)
[video4linux2,v4l2 @ ...] Dequeued v4l2 buffer contains corrupted data (12394880 bytes)
```

**Cause:** The capture card's USB firmware is sending incomplete or malformed NV12 video frames.

**Frequency:** If you see this repeatedly in `journalctl -u usb-capture-ffmpeg.service`, corruption is persistent.

### Timeout and "failed to log status" Errors

```
error: v4l2-input: /dev/video0: select timed out
error: v4l2-input: /dev/video0: failed to log status
```

**Cause:** FFmpeg is trying to read frames, but the device is slow or not producing data (e.g., "No Connection" status page on the capture card).

**Why it matters:** Even though the card displays video (a status page), it's not sending proper video frames through USB.

---

## Diagnosis Workflow

### Step 1: Validate Device Capture Quality

```bash
sudo ./scripts/validate_capture.sh /dev/video0 3840x2160 5
```

This test:
- Captures 5 seconds at 4K@30fps
- Counts corrupted frames and timeouts
- Tests at lower resolution (1080p) if issues found
- Reports USB power status
- **Recommends whether 4K or 1080p is safe**

**Example output:**
```
[TEST 1] Capturing at 3840x2160@30fps for 5s...
Results:
  Corrupted frames: 47
  Timeout errors: 3
  Total errors: 50

[TEST 2] Retesting at 1920x1080 (lower resolution)...
Results at 1080p:
  Corrupted frames: 2
  Timeout errors: 0

✓ RECOMMENDATION: Use 1920x1080 instead of 4K (less corrupted frames)
```

### Step 2: Check the Input Signal

**This is the most common cause of corruption:**

```bash
# What does the capture card display?
# - Valid HDMI signal from source? → Proceed to Step 3
# - "No Connection" / "No Input" page? → **CONNECT AN HDMI SOURCE**
# - Garbled/distorted video? → Source may be incompatible
```

**To test without a live source, feed a test pattern:**

```bash
# Terminal 1: Generate test pattern for 60 seconds
ffmpeg -f lavfi -i testsrc=size=3840x2160:duration=60 -f v4l2 /dev/video0

# Terminal 2 (in another tab): Validate
sudo ./scripts/validate_capture.sh /dev/video0 3840x2160 5
```

If corruption **disappears with test pattern**, the issue is your input source, not the device.

### Step 3: Check USB Power Management

USB autosuspend can cause timeouts and buffer hangs:

```bash
# Find your device's VID:PID
lsusb | grep -i "your-device-name"
# Example output: ID <VID>:<PID> Manufacturer DeviceName

# Check current power status
cat /sys/bus/usb/devices/*/power/control

# Check if autosuspend delay is set
cat /sys/bus/usb/devices/*/power/autosuspend_delay_ms
```

**If power/control shows `auto`, disable autosuspend:**

```bash
sudo ./scripts/optimise_device.sh <VID>:<PID>
# Disables autosuspend and sets power settings for stability
```

### Step 4: Check USB Bus Load

If corruption is specific to 4K@30fps but clean at 1080p, you may be hitting USB bandwidth limits:

```bash
# Find your device's VID:PID first
lsusb | grep -i "your-device-name"
# Example lsusb | grep -i "ugreen"

# Check USB bus speed (should be 480+ Mbps for USB 2.0, 5000+ for USB 3.x)
lsusb -v -d <VID>:<PID> 2>/dev/null | grep -iE 'speed|bcdUSB'

# Check for USB errors in kernel logs
dmesg | tail -50 | grep -iE 'usb.*error|xhci.*error|endpoint'
```

**If device is on USB 2.0 (480 Mbps):**
- 4K NV12 @ 30fps = ~3Gbps (impossible on USB 2.0)
- **Use 1920x1080 or USB 3.x port**

---

## Solutions by Root Cause

### Cause 1: No Input Signal to Card

**Symptom:** Card displays "No Connection" or status page. Corruption messages appear.

**Fix:**
```bash
# Connect HDMI source to the card's input
# (gaming console, second computer, camera, etc.)

# Or feed test pattern (for testing)
ffmpeg -f lavfi -i testsrc=size=3840x2160 -f v4l2 /dev/video0
```

### Cause 2: 4K USB Bandwidth Exceeded

**Symptom:** 4K@30fps has corruption, but 1080p@30fps is clean.

**Fix:**
```bash
# Edit /etc/default/usb-capture
sudo nano /etc/default/usb-capture

# Change:
USB_CAPTURE_RES=1920x1080
USB_CAPTURE_FPS=30

# Restart service
sudo systemctl restart usb-capture-ffmpeg.service

# Verify clean capture
sudo ./scripts/validate_capture.sh /dev/video0 1920x1080 5
```

### Cause 3: USB Autosuspend Enabled

**Symptom:** Timeouts and "failed to log status" errors, especially after idle periods.

**Fix:**
```bash
# Disable autosuspend for your device
sudo ./scripts/optimise_device.sh <VID>:<PID>

# Make it persistent (survives reboot)
sudo nano /etc/udev/rules.d/99-usb-capture-optimisation.rules
```

Add rule (replace <VID> and <PID> with your device's values):
```udev
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="<VID>", ATTR{idProduct}=="<PID>", ATTR{power/control}="on", ATTR{power/autosuspend_delay_ms}="-1"
```

Then reload:
```bash
sudo udevadm control --reload-rules && sudo udevadm trigger
```

### Cause 4: Device on Wrong USB Port

**Symptom:** Corruption on one port, clean on another.

**Fix:**
- Try different USB port (ideally motherboard ports, not hub)
- Use USB 3.x port (faster) if available
- Avoid sharing with other high-bandwidth devices (external HDD, etc.)

### Cause 5: Outdated Capture Card Firmware

**Symptom:** Corruption persists despite trying all above.

**Fix:**
```bash
# Find your device manufacturer
lsusb | grep <VID>:<PID>

# Check manufacturer's website for firmware update
# Look for: firmware.bin, firmware.hex, or driver package

# Follow manufacturer's firmware update procedure
# (Usually involves Windows software or UEFI update utility)
```

---

## Running with Corrupted Hardware (Workaround)

If your capture card has persistent corruption but you need to use it, the **v4l2loopback architecture isolates the problem**:

1. **FFmpeg process** crashes or stalls from corrupted frames → auto-restarts in ~2 seconds
2. **OBS reads** from stable `/dev/video10` (v4l2loopback) → **continues uninterrupted**
3. **Auto-reconnect monitor** detects FFmpeg failure and restarts it

**To enable automatic restart on corruption:**

```bash
# Edit service to have automatic restart
sudo systemctl edit usb-capture-ffmpeg.service

# Add under [Service]:
Restart=on-failure
RestartSec=2
StartLimitInterval=60
StartLimitBurst=10
```

Then:
```bash
sudo systemctl daemon-reload
sudo systemctl restart usb-capture-ffmpeg.service

# Monitor restarts
journalctl -u usb-capture-ffmpeg.service -f
```

**Result:** OBS stays stable while FFmpeg auto-recovers from buffer corruption.

---

## Advanced: Manual Buffer Analysis

If you want to inspect the exact bytes being corrupted:

```bash
# Capture raw frames to file (adjust resolution to your setup)
ffmpeg -f v4l2 -video_size <WIDTH>x<HEIGHT> -framerate <FPS> -i /dev/video0 -t 5 -f rawvideo out.raw 2>&1 | tee capture.log

# Example: 4K@30fps
ffmpeg -f v4l2 -video_size 3840x2160 -framerate 30 -i /dev/video0 -t 5 -f rawvideo out.raw 2>&1 | tee capture.log

# Analyze corruption patterns
grep -i "corrupted" capture.log | head -20

# Check frame size (should be WIDTH*HEIGHT*1.5 bytes for NV12)
# Example for 4K: 3840*2160*1.5 = 12,441,600 bytes
ls -lah out.raw
```

If file size is smaller than expected or contains repeated patterns, the device is definitely sending incomplete frames.

---

## Summary Decision Tree

```
Running validate_capture.sh?
├─ Corrupted frames > 5?
│  ├─ Card displays "No Connection"?
│  │  └─ → SOLUTION: Connect HDMI source
│  ├─ Corruption at 4K but clean at 1080p?
│  │  └─ → SOLUTION: Set USB_CAPTURE_RES=1920x1080
│  └─ Corruption at both resolutions?
│     └─ → Check autosuspend: sudo ./scripts/optimise_device.sh VID:PID
├─ Timeout errors > 2?
│  ├─ After idle time?
│  │  └─ → SOLUTION: Disable autosuspend (udev rule)
│  └─ During capture?
│     └─ → SOLUTION: Try different USB port or upgrade cable
└─ No errors?
   └─ ✓ Device is stable, proceed with OBS
```

---

## Support

If issues persist after troubleshooting:

1. **Collect logs:**
   ```bash
   journalctl -u usb-capture-ffmpeg.service -n 100 > usb_capture.log
   dmesg | grep -iE 'usb|xhci|uvc' > kernel_usb.log
   lsusb -vvv > lsusb_verbose.log
   ```

2. **Report with:**
   - Device name and VID:PID
   - Kernel version: `uname -r`
   - FFmpeg version: `ffmpeg -version | head -1`
   - Logs from above
   - Steps taken and results
