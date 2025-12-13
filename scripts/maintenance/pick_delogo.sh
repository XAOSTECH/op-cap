#!/usr/bin/env bash
# A helper to let a user pick delogo coordinates. Requires either 'slop' (visual selection) or manual input.
# Usage: ./pick_delogo.sh /dev/video0
MAINTENANCE_DESC="Visually select logo region to hide"
MAINTENANCE_ARGS="device_path"

set -euo pipefail
DEV=${1:-/dev/video0}
if [ ! -c "$DEV" ]; then
  echo "$DEV is not available"
  exit 2
fi

if command -v slop >/dev/null 2>&1; then
  read -p "Do you want to pick the logo area visually using slop? (Y/n) " choice
else
  echo "slop is not installed; interactive visual selection is unavailable. We'll ask you for numbers (x,y,w,h)."
  choice=n
fi

if [[ "$choice" =~ ^[Yy]$ ]] || [[ "$choice" == "" ]]; then
  echo "Launching ffplay for visual selection. Drag to mark the region when the frame is visible. Close ffplay after selection."
  # Start a small ffplay in the background
  ffplay -noborder -x 960 -y 540 -i "$DEV" &
  FF_PID=$!
  echo "ffplay started (pid $FF_PID). Please use slop to pick a rectangle in your display."
  echo "Click or drag inside the ffplay window to select the rectangle."
  RECT=$(slop -f "%x:%y:%w:%h")
  kill $FF_PID || true
  if [ -z "$RECT" ]; then
    echo "No selection captured; aborting"
    exit 3
  fi
  X=$(echo $RECT | cut -d: -f1)
  Y=$(echo $RECT | cut -d: -f2)
  W=$(echo $RECT | cut -d: -f3)
  H=$(echo $RECT | cut -d: -f4)
else
  read -rp "Enter x: " X
  read -rp "Enter y: " Y
  read -rp "Enter width: " W
  read -rp "Enter height: " H
fi

DELOGO="delogo=x=${X}:y=${Y}:w=${W}:h=${H}:show=0"
DRAWBOX="drawbox=x=${X}:y=${Y}:w=${W}:h=${H}:color=black@1:t=fill"
echo "Detected delogo filter: $DELOGO"

# Offer to set in env file /etc/default/usb-capture
if [ -w /etc/default/usb-capture ] || [ -e /etc/default/usb-capture ]; then
  echo "Attempting to write delogo to /etc/default/usb-capture (USB_CAPTURE_DELOGO)"
  # Ask which filter the user wants to write
  read -p "Write delogo or drawbox into /etc/default/usb-capture? (1) delogo (default), (2) drawbox: " user_choice
  if [[ "$user_choice" == "2" ]]; then
    sudo sed -i '/^USB_CAPTURE_DRAWBOX=/d' /etc/default/usb-capture || true
    echo "USB_CAPTURE_DRAWBOX='$DRAWBOX'" | sudo tee -a /etc/default/usb-capture >/dev/null
    echo "Set USB_CAPTURE_DRAWBOX to $DRAWBOX"
  else
    sudo sed -i '/^USB_CAPTURE_DELOGO=/d' /etc/default/usb-capture || true
    echo "USB_CAPTURE_DELOGO='$DELOGO'" | sudo tee -a /etc/default/usb-capture >/dev/null
    echo "Set USB_CAPTURE_DELOGO to $DELOGO"
  fi
  echo "Updated /etc/default/usb-capture. To apply immediately, restart the usb-capture-ffmpeg.service"
  read -p "Restart the service now? (Y/n) " restart_choice
  if [[ "$restart_choice" =~ ^[Yy]$ ]] || [[ "$restart_choice" == "" ]]; then
    sudo systemctl restart usb-capture-ffmpeg.service || true
  fi
else
  echo "No /etc/default/usb-capture file found, printing command to export variable instead:" 
  echo "export USB_CAPTURE_DELOGO='$DELOGO'"
fi

exit 0
