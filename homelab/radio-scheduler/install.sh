#!/bin/bash
# Installs radio-scheduler as a systemd *user* service on a Linux machine that is always on.
# Usage: ./install.sh <radio-ip> [pin] [token]
#   token: paste the one copied from the app (Settings → Scheduler → Copy token).
set -euo pipefail
RADIO_HOST="${1:?usage: ./install.sh <radio-ip> [pin] [token]}"
RADIO_PIN="${2:-1234}"
TOKEN="${3:-}"
DIR="$HOME/radio-scheduler"
UNIT_DIR="$HOME/.config/systemd/user"
SRC="$(cd "$(dirname "$0")" && pwd)"

command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }
mkdir -p "$DIR" "$UNIT_DIR"
cp "$SRC/scheduler.py" "$DIR/"
sed -e "s/__RADIO_HOST__/$RADIO_HOST/" -e "s/__RADIO_PIN__/$RADIO_PIN/" \
    "$SRC/radio-scheduler.service" > "$UNIT_DIR/radio-scheduler.service"

if [ -n "$TOKEN" ]; then
  printf '%s\n' "$TOKEN" > "$DIR/token"
elif [ ! -s "$DIR/token" ]; then
  echo "No token given. Paste it later into $DIR/token and run: systemctl --user restart radio-scheduler"
  python3 -c 'import secrets; print(secrets.token_hex(24))' > "$DIR/token"
fi
chmod 600 "$DIR/token"

# Keep the user service running without an open login session.
loginctl enable-linger "$USER" 2>/dev/null || echo "Note: run 'sudo loginctl enable-linger $USER' so the service survives logout."
systemctl --user daemon-reload
systemctl --user enable --now radio-scheduler
sleep 1
curl -fsS localhost:8735/health && echo && echo "radio-scheduler is running."
