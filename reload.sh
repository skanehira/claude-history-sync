#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Optional overrides
NEW_INTERVAL=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Regenerate service config from template and reload.

Options:
  --interval SECONDS  override sync interval
  -h, --help          show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      if [[ $# -lt 2 || -z "${2:-}" || "$2" == --* ]]; then
        echo "Error: --interval requires a value"
        exit 1
      fi
      NEW_INTERVAL="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Error: unknown option: $1"; usage ;;
  esac
done

if [[ -n "$NEW_INTERVAL" ]]; then
  if ! [[ "$NEW_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$NEW_INTERVAL" -lt 60 ]]; then
    echo "Error: --interval must be a number >= 60 (seconds)"
    exit 1
  fi
fi

OS="$(uname -s)"
case "$OS" in
  Darwin)
    PLIST_NAME="com.rclone.claude-sync.plist"
    PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}"

    if [[ ! -f "$PLIST_PATH" ]]; then
      echo "Error: ${PLIST_PATH} not found. Run setup.sh first."
      exit 1
    fi

    # Extract current values from installed plist
    RCLONE_PATH=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$PLIST_PATH")
    CLAUDE_PROJECTS_DIR=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:2" "$PLIST_PATH")
    REMOTE_BUCKET=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:3" "$PLIST_PATH")
    REMOTE="${REMOTE_BUCKET%%:*}"
    BUCKET="${REMOTE_BUCKET#*:}"
    INTERVAL=$(/usr/libexec/PlistBuddy -c "Print :StartInterval" "$PLIST_PATH")
    LOG_FILE=$(/usr/libexec/PlistBuddy -c "Print :StandardOutPath" "$PLIST_PATH")

    # Apply overrides
    if [[ -n "$NEW_INTERVAL" ]]; then
      INTERVAL="$NEW_INTERVAL"
    fi

    # Escape pipe characters for sed delimiter
    REMOTE_ESC="${REMOTE//|/\\|}"
    BUCKET_ESC="${BUCKET//|/\\|}"

    # Regenerate plist from template
    sed \
      -e "s|__RCLONE_PATH__|${RCLONE_PATH}|g" \
      -e "s|__CLAUDE_PROJECTS_DIR__|${CLAUDE_PROJECTS_DIR}|g" \
      -e "s|__REMOTE__|${REMOTE_ESC}|g" \
      -e "s|__BUCKET__|${BUCKET_ESC}|g" \
      -e "s|__INTERVAL__|${INTERVAL}|g" \
      -e "s|__LOG_FILE__|${LOG_FILE}|g" \
      "${SCRIPT_DIR}/templates/com.rclone.claude-sync.plist" > "$PLIST_PATH"

    # Reload service
    DOMAIN="gui/$(id -u)"
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load -w "$PLIST_PATH"

    echo "Reloaded: ${PLIST_PATH} (interval: ${INTERVAL}s)"
    ;;

  Linux)
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    SERVICE_PATH="${SYSTEMD_DIR}/claude-sync.service"

    if [[ ! -f "$SERVICE_PATH" ]]; then
      echo "Error: ${SERVICE_PATH} not found. Run setup.sh first."
      exit 1
    fi

    # Extract current values from installed service
    EXEC_LINE=$(grep "^ExecStart=" "$SERVICE_PATH")
    RCLONE_PATH=$(echo "$EXEC_LINE" | awk '{print $1}' | cut -d= -f2)
    CLAUDE_PROJECTS_DIR=$(echo "$EXEC_LINE" | awk '{print $3}')
    REMOTE_BUCKET=$(echo "$EXEC_LINE" | awk '{print $4}')
    REMOTE="${REMOTE_BUCKET%%:*}"
    BUCKET="${REMOTE_BUCKET#*:}"

    TIMER_PATH="${SYSTEMD_DIR}/claude-sync.timer"
    INTERVAL_MIN=$(grep "^OnUnitActiveSec=" "$TIMER_PATH" | sed 's/OnUnitActiveSec=\([0-9]*\)min/\1/')

    # Apply overrides
    if [[ -n "$NEW_INTERVAL" ]]; then
      INTERVAL_MIN=$(( NEW_INTERVAL / 60 ))
      if [[ $INTERVAL_MIN -lt 1 ]]; then
        INTERVAL_MIN=1
      fi
    fi

    REMOTE_ESC="${REMOTE//|/\\|}"
    BUCKET_ESC="${BUCKET//|/\\|}"

    # Regenerate from templates
    sed \
      -e "s|__RCLONE_PATH__|${RCLONE_PATH}|g" \
      -e "s|__CLAUDE_PROJECTS_DIR__|${CLAUDE_PROJECTS_DIR}|g" \
      -e "s|__REMOTE__|${REMOTE_ESC}|g" \
      -e "s|__BUCKET__|${BUCKET_ESC}|g" \
      "${SCRIPT_DIR}/templates/claude-sync.service" > "$SERVICE_PATH"

    sed \
      -e "s|__INTERVAL_MIN__|${INTERVAL_MIN}|g" \
      "${SCRIPT_DIR}/templates/claude-sync.timer" > "$TIMER_PATH"

    systemctl --user daemon-reload
    systemctl --user restart claude-sync.timer

    echo "Reloaded: ${SERVICE_PATH} (interval: ${INTERVAL_MIN}min)"
    ;;

  *)
    echo "Unsupported OS: $OS"
    exit 1
    ;;
esac
