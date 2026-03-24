#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"

# Defaults
REMOTE="gdrive"
BUCKET="dev/claude-projects"
INTERVAL=300  # seconds (5 minutes)

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --remote NAME      rclone remote name (default: gdrive)
  --bucket NAME      remote bucket/folder name (default: dev/claude-projects)
  --interval SECONDS sync interval in seconds, minimum 60 (default: 300)
  -h, --help         show this help
EOF
  exit 0
}

require_arg() {
  if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
    echo "Error: $1 requires a value"
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)   require_arg "$1" "${2:-}"; REMOTE="$2"; shift 2 ;;
    --bucket)   require_arg "$1" "${2:-}"; BUCKET="$2"; shift 2 ;;
    --interval) require_arg "$1" "${2:-}"; INTERVAL="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *)          echo "Error: unknown option: $1"; usage ;;
  esac
done

# Validate --interval
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [[ "$INTERVAL" -lt 60 ]]; then
  echo "Error: --interval must be a number >= 60 (seconds)"
  exit 1
fi

INTERVAL_MIN=$(( INTERVAL / 60 ))

# --- Preflight checks ---

if ! command -v rclone &>/dev/null; then
  echo "Error: rclone is not installed."
  echo "  macOS:  brew install rclone"
  echo "  Linux:  https://rclone.org/install/"
  exit 1
fi

RCLONE_PATH="$(command -v rclone)"

if ! rclone listremotes | grep -q "^${REMOTE}:$"; then
  echo "rclone remote '${REMOTE}' not found."
  read -rp "Run 'rclone config' to create it now? [y/N] " answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "Aborted. Run 'rclone config' manually, then re-run setup.sh."
    exit 1
  fi
  rclone config
  if ! rclone listremotes | grep -q "^${REMOTE}:$"; then
    echo "Error: rclone remote '${REMOTE}' still not found after configuration."
    exit 1
  fi
fi

echo "Verifying remote '${REMOTE}' connection..."
if ! rclone lsf "${REMOTE}:" --max-depth 0 &>/dev/null; then
  echo "Error: remote '${REMOTE}' exists but connection failed."
  echo "Run 'rclone config reconnect ${REMOTE}:' to fix authentication."
  exit 1
fi

if [[ ! -d "$CLAUDE_PROJECTS_DIR" ]]; then
  echo "Error: $CLAUDE_PROJECTS_DIR does not exist."
  echo "Make sure Claude Code has been used at least once."
  exit 1
fi

# --- Initial resync ---

is_already_setup() {
  local OS
  OS="$(uname -s)"
  case "$OS" in
    Darwin)
      [[ -f "$HOME/Library/LaunchAgents/com.rclone.claude-sync.plist" ]]
      ;;
    Linux)
      [[ -f "$HOME/.config/systemd/user/claude-sync.timer" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

if is_already_setup; then
  echo "Existing setup detected. Skipping initial resync."
  echo "To force a full resync, run uninstall.sh first, then re-run setup.sh."
else
  # Create remote directory if it doesn't exist
  rclone mkdir "${REMOTE}:${BUCKET}" 2>/dev/null || true

  echo "Running initial bisync (dry-run)..."
  rclone bisync "$CLAUDE_PROJECTS_DIR" "${REMOTE}:${BUCKET}" \
    --resync --resync-mode newer --dry-run -MvP

  echo ""
  read -rp "Dry-run complete. Proceed with actual resync? [y/N] " answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi

  echo "Running initial bisync..."
  rclone bisync "$CLAUDE_PROJECTS_DIR" "${REMOTE}:${BUCKET}" \
    --resync --resync-mode newer -MvP

  echo "Initial sync complete."
fi

# --- Register periodic sync ---

# Escape pipe characters for sed delimiter
REMOTE_ESC="${REMOTE//|/\\|}"
BUCKET_ESC="${BUCKET//|/\\|}"

OS="$(uname -s)"
case "$OS" in
  Darwin)
    PLIST_NAME="com.rclone.claude-sync.plist"
    PLIST_DIR="$HOME/Library/LaunchAgents"
    PLIST_PATH="${PLIST_DIR}/${PLIST_NAME}"
    LOG_FILE="$HOME/Library/Logs/rclone-claude-sync.log"

    mkdir -p "$PLIST_DIR"

    sed \
      -e "s|__RCLONE_PATH__|${RCLONE_PATH}|g" \
      -e "s|__CLAUDE_PROJECTS_DIR__|${CLAUDE_PROJECTS_DIR}|g" \
      -e "s|__REMOTE__|${REMOTE_ESC}|g" \
      -e "s|__BUCKET__|${BUCKET_ESC}|g" \
      -e "s|__INTERVAL__|${INTERVAL}|g" \
      -e "s|__LOG_FILE__|${LOG_FILE}|g" \
      "${SCRIPT_DIR}/templates/com.rclone.claude-sync.plist" > "$PLIST_PATH"

    launchctl bootout "gui/$(id -u)/${PLIST_NAME}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

    echo "launchd service registered: ${PLIST_PATH}"
    echo "Log file: ${LOG_FILE}"
    ;;

  Linux)
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_DIR"

    sed \
      -e "s|__RCLONE_PATH__|${RCLONE_PATH}|g" \
      -e "s|__CLAUDE_PROJECTS_DIR__|${CLAUDE_PROJECTS_DIR}|g" \
      -e "s|__REMOTE__|${REMOTE_ESC}|g" \
      -e "s|__BUCKET__|${BUCKET_ESC}|g" \
      "${SCRIPT_DIR}/templates/claude-sync.service" > "${SYSTEMD_DIR}/claude-sync.service"

    sed \
      -e "s|__INTERVAL_MIN__|${INTERVAL_MIN}|g" \
      "${SCRIPT_DIR}/templates/claude-sync.timer" > "${SYSTEMD_DIR}/claude-sync.timer"

    systemctl --user daemon-reload
    systemctl --user enable --now claude-sync.timer

    echo "systemd timer registered and started."
    echo "Check status: systemctl --user status claude-sync.timer"
    echo "View logs:    journalctl --user -u claude-sync"
    ;;

  *)
    echo "Unsupported OS: $OS"
    echo "You can manually set up a cron job:"
    echo "  */${INTERVAL_MIN} * * * * ${RCLONE_PATH} bisync ${CLAUDE_PROJECTS_DIR} ${REMOTE}:${BUCKET} --resilient --recover --max-lock 2m --conflict-resolve newer --max-delete 50 -MvP"
    exit 1
    ;;
esac

echo ""
echo "Setup complete! Projects will sync every ${INTERVAL_MIN} minute(s)."
