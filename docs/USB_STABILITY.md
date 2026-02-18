# USB Capture Device Stability Troubleshooting

## Your Issue: UGREEN 25173 Crashing During Capture

**Symptoms:**
- v4l2-input: select timeout
- Device disconnects after minutes of recording
- OBS crashes with "double free or corruption"

**Cause:** Physical USB connection instability or USB power delivery issue

---

## USB-C Bandwidth & Cable Quality

### USB 3.0/3.1 vs USB-C
You asked: **"Can USB 3.0/3.1 cables properly support USB-C bandwidth?"**

✅ **YES**, but with caveats:

| Spec | Bandwidth | USB-C Support | Notes |
|------|-----------|---------------|-------|
| **USB 3.0** | 5 Gbps | Via adapter | Works, older standard |
| **USB 3.1 Gen 1** | 5 Gbps | Native | Same speed as 3.0 |
| **USB 3.1 Gen 2** | 10 Gbps | Native | Full speed for UGREEN |
| **USB 3.2** | 10-20 Gbps | Native | Best choice |

**Bottom line for UGREEN 25173:**
- ✅ USB 3.1 Gen 2 **IS** the native speed (10 Gbps)
- ✅ Passive USB-C to USB-A adapters work fine
- ⚠️ **Cable quality matters more than adapter**

---

## Root Cause Analysis

### Most Likely: Loose Motherboard USB-C Port

UGREEN 25173 with unstable motherboard USB-C connector is a **known hardware issue**:

```
Symptoms in your setup:
  - Works at first
  - Crashes after 5-10 minutes
  - Stream "hangs" before disconnect
  - Device disconnects cleanly (not power reset)
  → All point to LOOSE PHYSICAL CONNECTION
```

**Check BIOS USB-C Power Delivery:**

```bash
# While device is connected, monitor power:
sudo cat /sys/bus/usb/devices/*/power/control | grep -v auto

# Should show "on" not "auto"
# If "auto", autosuspend will power off device mid-stream
```

### Secondary: USB Power Delivery Insufficient

The UGREEN 25173 needs **consistent 5V/3A** from USB port:

```bash
# Check USB power limits
cat /sys/bus/usb/devices/*/power_state
cat /sys/bus/usb/devices/*/bMaxPower

# If bMaxPower shows <500mA, your port can't supply enough power
```

---

## Solutions (In Order of Likelihood)

### 1. USE A DIFFERENT USB PORT

**What to try:**
- USB 3.0 ports on back of motherboard (not front panel)
- Different USB header on motherboard
- USB 3.1 port if available
- Avoid USB hubs unless powered

**Why:** Front panel USB ports often share bandwidth or have limited power delivery

### 2. GET A HIGH-QUALITY USB CABLE

**Get this type:**
- **5ft max** USB 3.1 Gen 2 Type-C cable
- **Certified** USB-C E-Marker (actively identifies safe power delivery)
- **Non-passive**: Active cable with built-in controller
- **Brands:** Anker, Belkin, Apple (expensive but works)

**Test cable:**
```bash
# Check if cable is properly detected
lsusb -v -d 3188:1000 | grep -i "maxPower"
# Should show 500 or 900 mA minimum
```

### 3. DISABLE USB AUTOSUSPEND

This is the quick fix that might help immediately:

```bash
# Disable autosuspend for your device (PERMANENTLY)
echo "options usbcore autosuspend=-1" | sudo tee /etc/modprobe.d/usb-autosuspend.conf

# Apply immediately
sudo modprobe -r usbcore && sudo modprobe usbcore

# Verify
cat /sys/bus/usb/devices/*/power/autosuspend_delay_ms
# Should show -1 (disabled)
```

Or per-device:
```bash
# Find your device bus number
lsusb | grep -i "3188:1000"
# Example output: Bus 002 Device 005: ID 3188:1000 ITE UGREEN 25173

# Set autosuspend to -1 (disabled)
echo -1 | sudo tee /sys/bus/usb/devices/2-1/power/autosuspend_delay_ms

# Verify it stays (across reboot, may need udev rule)
```

### 4. BIOS SETTINGS (If Available)

In BIOS, check for:
- **USB Power Delivery settings** → Set to "Always On" or "High"
- **USB-C port settings** → Disable power saving
- **Errata/Fixes** → Update BIOS to latest version (sometimes has USB fixes)

---

## Why Restarting OBS Isn't Enough

The `obs-safe` launcher restarts OBS, but:

1. ❌ **OBS restart handles crashed application, NOT hardware recovery**
2. ❌ **The USB device stays disconnected after crash**
3. ❌ **Without auto-reconnect service, device can't recover**

**What's needed:**
- Auto-reconnect service watching `/dev/video0`
- USB reset (full power cycle of device)
- Stream resume automation

---

## HARDER SOLUTION: Mechanical Fix

If none of the software fixes work, the **motherboard USB-C port is faulty**:

```
Permanent Hardware Solutions:
1. Use external USB-C hub (powered, 5V/3A minimum)
   - Typically more stable than motherboard ports
   - Cost: $20-50 (Anker, Amazon Basics)

2. USB Hub with per-port power control
   - Can reset individual ports without full reboot
   - Example: Anker PowerExpand 7-in-1 ($50-80)

3. Contact UGREEN support
   - Some units have defective firmware
   - They may send patched version
```

---

## USB Cable Bandwidth Reality Check

For 4K@30fps capture:

```
Bandwidth needed:
  3840×2160×30fps = 248 Mbps (compressed HDMI → USB)
  
Available bandwidth:
  USB 3.0/3.1 Gen 1: 5,000 Mbps
  USB 3.1 Gen 2: 10,000 Mbps
  
Ratio: Only 5% of available bandwidth used
→ Bandwidth is NOT the problem
→ Physical connection IS the problem
```

---

## Testing Procedure

Try these in order:

### Test 1: Quick USB Disable/Enable
```bash
# Find device
lsusb | grep "3188:1000"
# Output: Bus 002 Device 005: ID 3188:1000

# Disable autosuspend
echo -1 | sudo tee /sys/bus/usb/devices/2-5/power/autosuspend_delay_ms

# Start capture in OBS, monitor for 30 seconds
# expected: Works without timeout
```

### Test 2: Try Different Port
- Unplug from current port
- Plug into different USB 3 port
- Let it re-enumerate
- Start OBS capture
- Run for 10 minutes

### Test 3: Test Cable & Port Together
```bash
# Stress test with ffmpeg (no OBS overhead)
ffmpeg -f v4l2 -video_size 3840x2160 -framerate 30 -i /dev/video0 \
  -c:v libx264 -preset ultrafast -t 600 /tmp/stress_test.mp4

# If this works 10 minutes without timeout, cable/port is OK
# If it fails, hardware issue confirmed
```

---

## Next Steps for YOU

**Do this now:**

```bash
# 1. Set your project directory permanently
echo "export OBS_SAFE_BASEDIR=/home/jnxlr/PRO/WEB/CST/op-cap" >> ~/.bashrc
source ~/.bashrc

# 2. Reinstall safe launcher
cd /home/jnxlr/PRO/WEB/CST/op-cap
make install-safe-launcher

# 3. Run driver optimization (creates wrapper)
sudo make optimise-drivers

# 4. Disable autosuspend
echo "options usbcore autosuspend=-1" | sudo tee /etc/modprobe.d/usb-autosuspend.conf
sudo modprobe -r usbcore 2>/dev/null || true
sudo modprobe usbcore

# 5. Try different USB port (if available)
# Then test OBS
```

**If still crashing:**

```bash
# Check USB power limits
lsusb -v -d 3188:1000 | grep -i maxpower

# If < 500mA, buy powered USB hub
# If > 500mA, cable/port is suspect, replace

# Monitor for timeouts
journalctl -f | grep -i "select timed out"
```

---

## References

- [UGREEN Support](https://www.ugreen.com) - Contact for firmware updates
- [Linux USB Documentation](https://www.kernel.org/doc/html/latest/driver-api/usb/usb.html)
- [USB Power Delivery Spec](https://www.usb.org/documents) - Technical details
- [ffmpeg v4l2 Capturing](https://ffmpeg.org/ffmpeg-devices.html#video4linux2,-v4l2)

---

**Bottom line:** Your USB-C port or cable is the problem, not the software. Fix the hardware, software will work.
