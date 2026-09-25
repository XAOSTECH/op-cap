#!/usr/bin/env bash
set -euo pipefail

BASEDIR="$(cd "$(dirname "$0")/.." && pwd)"
REMOVE_ONLY=0

while (($#)); do
  case "$1" in
    --basedir)
      BASEDIR="$2"
      shift 2
      ;;
    --remove)
      REMOVE_ONLY=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: generate_obs_aliases.sh [--basedir /path/to/op-cap] [--remove]

Installs host launchers in /usr/local/bin:
  sobs -> safe OBS with --no-loopback --no-device
  cobs -> choose /dev/video* and launch safe OBS with --device=<selection>

Set OBS_SAFE_BASEDIR to override project path at runtime.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

SOBS_PATH="/usr/local/bin/sobs"
COBS_PATH="/usr/local/bin/cobs"

if [[ "$REMOVE_ONLY" -eq 1 ]]; then
  if [[ $EUID -eq 0 ]]; then
    rm -f "$SOBS_PATH" "$COBS_PATH"
  else
    sudo rm -f "$SOBS_PATH" "$COBS_PATH"
  fi
  echo "Removed: $SOBS_PATH, $COBS_PATH"
  exit 0
fi

if [[ ! -f "$BASEDIR/scripts/obs-safe-launch.sh" ]]; then
  echo "ERROR: $BASEDIR/scripts/obs-safe-launch.sh not found" >&2
  exit 1
fi

write_file() {
  local path="$1"
  local content="$2"
  if [[ $EUID -eq 0 ]]; then
    cat > "$path" <<< "$content"
    chmod +x "$path"
  else
    printf '%s\n' "$content" | sudo tee "$path" >/dev/null
    sudo chmod +x "$path"
  fi
}

SOBS_CONTENT=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="\${OBS_SAFE_BASEDIR:-$BASEDIR}"
LAUNCHER="\$PROJECT_DIR/scripts/obs-safe-launch.sh"

if [[ ! -f "\$LAUNCHER" ]]; then
  echo "ERROR: obs-safe-launch.sh not found at \$LAUNCHER" >&2
  echo "Set OBS_SAFE_BASEDIR to your op-cap checkout path." >&2
  exit 1
fi

exec "\$LAUNCHER" --basedir "\$PROJECT_DIR" --no-loopback --no-device "\$@"
EOF
)

COBS_CONTENT=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="\${OBS_SAFE_BASEDIR:-$BASEDIR}"
LAUNCHER="\$PROJECT_DIR/scripts/obs-safe-launch.sh"

if [[ ! -f "\$LAUNCHER" ]]; then
  echo "ERROR: obs-safe-launch.sh not found at \$LAUNCHER" >&2
  echo "Set OBS_SAFE_BASEDIR to your op-cap checkout path." >&2
  exit 1
fi

mapfile -t VIDEO_DEVICES < <(
  for _d in /dev/video*; do
    [[ -c "\$_d" ]] || continue
    v4l2-ctl -d "\$_d" --list-formats 2>/dev/null | grep -q '\[0\]' && echo "\$_d"
  done
)
if [[ \${#VIDEO_DEVICES[@]} -eq 0 ]]; then
  echo "No video capture devices found (metadata-only nodes excluded)." >&2
  exit 1
fi

if [[ \${#VIDEO_DEVICES[@]} -eq 1 ]]; then
  CHOSEN="\${VIDEO_DEVICES[0]}"
else
  echo "Select capture device:"
  for i in "\${!VIDEO_DEVICES[@]}"; do
    printf '  [%s] %s\n' "\$i" "\${VIDEO_DEVICES[\$i]}"
  done

  while true; do
    read -rp "Choice: " CHOICE
    if [[ "\$CHOICE" =~ ^[0-9]+$ ]] && [[ "\$CHOICE" -ge 0 ]] && [[ "\$CHOICE" -lt "\${#VIDEO_DEVICES[@]}" ]]; then
      CHOSEN="\${VIDEO_DEVICES[\$CHOICE]}"
      break
    fi
    echo "Invalid choice"
  done
fi

echo "Using device: \$CHOSEN"
exec "\$LAUNCHER" --basedir "\$PROJECT_DIR" --device "\$CHOSEN" "\$@"
EOF
)

write_file "$SOBS_PATH" "$SOBS_CONTENT"
write_file "$COBS_PATH" "$COBS_CONTENT"

echo "Installed aliases:"
echo "  $SOBS_PATH -> obs-safe-launch --no-loopback --no-device"
echo "  $COBS_PATH -> pick /dev/video* then obs-safe-launch --device=<selection>"
