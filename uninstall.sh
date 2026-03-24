#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s)"
case "$OS" in
  Darwin)
    PLIST_NAME="com.rclone.claude-sync.plist"
    PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}"

    launchctl unload "$PLIST_PATH" 2>/dev/null || true

    if [[ -f "$PLIST_PATH" ]]; then
      rm "$PLIST_PATH"
      echo "Removed: ${PLIST_PATH}"
    else
      echo "Not found: ${PLIST_PATH}"
    fi
    ;;

  Linux)
    SYSTEMD_DIR="$HOME/.config/systemd/user"

    systemctl --user disable --now claude-sync.timer 2>/dev/null || true

    for f in claude-sync.service claude-sync.timer; do
      if [[ -f "${SYSTEMD_DIR}/${f}" ]]; then
        rm "${SYSTEMD_DIR}/${f}"
        echo "Removed: ${SYSTEMD_DIR}/${f}"
      else
        echo "Not found: ${SYSTEMD_DIR}/${f}"
      fi
    done

    systemctl --user daemon-reload
    ;;

  *)
    echo "Unsupported OS: $OS"
    echo "Remove any cron entries manually: crontab -e"
    exit 1
    ;;
esac

echo ""
echo "Uninstall complete."
echo "Note: rclone remote config and cloud data were not removed."
