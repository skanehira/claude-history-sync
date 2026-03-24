# claude-history-sync

Sync [Claude Code](https://claude.com/claude-code) conversation history across multiple machines using [rclone bisync](https://rclone.org/bisync/).

## How it works

Claude Code stores project-specific conversation history in `~/.claude/projects/`. This tool periodically syncs that directory to a cloud storage backend (Google Drive, S3, etc.) via rclone bisync, so you can access your conversation history from any machine.

```
Machine A  <-->  Cloud Storage  <-->  Machine B
                (Google Drive,
                 S3, R2, etc.)
```

## Prerequisites

- [rclone](https://rclone.org/install/) installed and a remote configured (`rclone config`)
- `~/.claude/projects/` directory exists (run Claude Code at least once)

## Setup

```bash
git clone https://github.com/skanehira/claude-history-sync.git
cd claude-history-sync
./setup.sh
```

### Options

| Flag                 | Description            | Default               |
| -------------------- | ---------------------- | --------------------- |
| `--remote NAME`      | rclone remote name     | `gdrive`              |
| `--bucket NAME`      | remote folder name     | `dev/claude-projects` |
| `--interval SECONDS` | sync interval (min 60) | `300` (5 min)         |

### Examples

```bash
# Use a custom remote and 10-minute interval
./setup.sh --remote mycloud --bucket claude-data --interval 600
```

## What setup.sh does

1. Checks that rclone is installed and the specified remote exists
2. Runs an initial `rclone bisync --resync` (with dry-run confirmation)
3. Registers a periodic sync job:
   - **macOS**: launchd (`~/Library/LaunchAgents/com.rclone.claude-sync.plist`)
   - **Linux**: systemd user timer (`~/.config/systemd/user/claude-sync.{service,timer}`)

If setup.sh detects an existing installation, it skips the initial resync and only updates the periodic sync configuration. To force a full resync, run `./uninstall.sh` first.

## Viewing logs

- **macOS**: `cat ~/Library/Logs/rclone-claude-sync.log`
- **Linux**: `journalctl --user -u claude-sync`

## Uninstall

```bash
./uninstall.sh
```

This removes the periodic sync job. It does **not** remove your rclone remote config or cloud data.

## Important notes

- **Project directory names include local paths** (e.g., `-Users-john-dev-myproject`). For syncing to work correctly, use the same directory structure for your projects on all machines.
- **Do not use two machines simultaneously.** This setup assumes only one machine is active at a time. Conflicts are resolved by keeping the newer file (`--conflict-resolve newer`).
- **Max delete safety**: If more than 50% of files would be deleted in a single sync, the operation is aborted to prevent accidental data loss.

## License

[MIT](LICENSE)
