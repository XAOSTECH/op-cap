#!/usr/bin/env bash
# Reset a USB hub port using uhubctl if available
# Usage: sudo ./uhubctl_reset.sh <hub:port> e.g. 1-1.4
MAINTENANCE_DESC="Power cycle USB hub port (requires uhubctl)"
MAINTENANCE_ARGS="hubport"

set -euo pipefail
if [ $# -ne 1 ]; then
  echo "Usage: $0 <hub:port> (e.g. 1-1.4)"
  exit 1
fi
if ! command -v uhubctl >/dev/null 2>&1; then
  echo "uhubctl not found; install it (https://github.com/mvp/uhubctl)"
  exit 1
fi
HUBPORT=$1
# Find hub based on sysfs name and turn power off/on

# uhubctl expects a hub port like 1-1.4, but you can also use physical hub index
sudo uhubctl -p "$HUBPORT" -a 0 || true
sleep 1
sudo uhubctl -p "$HUBPORT" -a 1 || true

echo "Done"
