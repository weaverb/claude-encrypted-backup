---
name: encrypted-backup
description: "Use when the user wants to set up, run, check, or restore an encrypted 3-2-1 backup for a sensitive local directory (financial, health, legal, or other private records) — e.g. \"back up my [folder]\", \"add [dir] to my backups\", \"run my backups\", \"is my backup up to date\", \"restore my backup\". Do not trigger for generic git/version-control requests unrelated to disaster-recovery backup."
---

# Encrypted Backup

## Purpose

Give sensitive personal directories (financial records, health records, estate/legal documents, or anything else worth protecting) real disaster-recovery protection — survives a dead disk, a stolen laptop, or a house fire — without ever putting readable data on a server that isn't the user's own machine.

Works on **Linux, macOS, and Windows** (via Git Bash or WSL — see [Platform notes](#platform-notes)), and mirrors offsite to **Google Drive, OneDrive, Proton Drive, or any other [rclone](https://rclone.org)-supported remote** — the user picks one or several; nothing here is tied to a specific provider.

## Architecture (3-2-1: 3 copies, 2 media, 1 offsite)

1. **Copy 1 — working directory.** The folder itself, unchanged.
2. **Local git history + staging restic repo (on the internal disk).**
   - `git init` **with no remote** inside the target directory gives free version history for every text/markdown/JSON edit. Purely local — never pushed anywhere.
   - A [restic](https://restic.net/) repository under `~/Backups/restic-repos/<name>/` holds encrypted, deduplicated, incremental snapshots of the *entire* directory (binaries included — PDFs, images, spreadsheets — which git handles poorly). Restic's own passphrase is independent of anything else, so this layer is already fully encrypted before either mirror below touches it. This repo is the source both mirrors below sync from.
3. **Copy 2 — the "2nd medium": an external drive (optional but recommended).** `rclone` mirrors the restic repo onto a separate physical drive, under `<mount>/ClaudeBackups/<name>/`. Skipped gracefully if unconfigured or the drive isn't connected when a backup runs.
4. **Copy 3 — one or more offsite cloud remotes.** `rclone` mirrors the same restic repository (nothing but opaque encrypted blobs) to whichever remote(s) the user has configured — Google Drive, OneDrive, Proton Drive, or anything else rclone supports — under the identical `ClaudeBackups/<name>/` structure. Each provider's own encryption (where offered, e.g. Proton's zero-access encryption) wraps the already-encrypted restic data again, but restic's encryption is what actually matters here: it's what makes it safe to store this on *any* provider's servers.

This satisfies 3-2-1 (3 copies: internal disk, external drive, cloud remote(s) / 2 media types: internal disk + external drive / 1 offsite: the cloud remote) without any plaintext ever leaving the machine — everything that leaves is already restic-encrypted first.

Configurable via environment variables — set once, e.g. in `~/.bashrc`/`~/.zshrc` (or the equivalent for your shell):

| Variable | Purpose | Default |
|---|---|---|
| `ENCRYPTED_BACKUP_RCLONE_REMOTES` | space-separated rclone remote names to mirror offsite, e.g. `"gdrive onedrive"` | *(unset — offsite mirroring skipped until configured)* |
| `ENCRYPTED_BACKUP_RCLONE_PATH` | base path under each remote | `ClaudeBackups` |
| `ENCRYPTED_BACKUP_LOCAL_MIRROR_MOUNT` | mount point of a second local drive | *(unset — local-drive mirroring skipped until configured)* |
| `ENCRYPTED_BACKUP_LOCAL_MIRROR_SUBDIR` | subdirectory under that mount | `ClaudeBackups` |

## Platform notes

- **Linux and macOS**: run natively — the helper script is a portable POSIX-ish bash script.
- **Windows**: run it under **Git Bash** (bundled with [Git for Windows](https://git-scm.com/download/win)) or **WSL**. WSL is the more reliable option since restic/rclone/jq install cleanly via your WSL distro's normal Linux package manager; Git Bash works too but tool installation is more manual (see prerequisites below).
- The script auto-detects the OS (`check` subcommand reports it) and adjusts its install hints and its "is the second drive connected" check accordingly. On macOS/Windows that check is a directory-existence heuristic rather than a true mountpoint check (macOS/Windows don't have a portable `mountpoint` equivalent) — good enough in practice, but know that limitation exists.

## One-time prerequisites (must be done by the user directly, not through Claude)

These steps involve secrets (a sudo/admin password, cloud credentials) that should never pass through the conversation transcript. Ask the user to run them via `!<command>` in their own terminal so entry stays local, then verify success yourself with read-only checks.

1. **Install tools** (if `scripts/backup.sh check` reports any missing):
   - **Linux**: `sudo dnf install -y restic rclone jq` (Fedora/RHEL/Bazzite), `sudo apt install -y restic rclone jq` (Debian/Ubuntu), or `sudo pacman -S restic rclone jq` (Arch)
   - **macOS**: `brew install restic rclone jq`
   - **Windows**: `winget install restic.restic rclone.rclone jqlang.jq`, or inside WSL, the Linux instructions for your WSL distro

2. **Configure at least one rclone remote** (if `rclone listremotes` shows none):
   ```
   ! rclone config
   ```
   Walk them through: `n` (new remote) → pick a name (e.g. `gdrive`, `onedrive`, `proton`) → choose the backend:
   - **Google Drive** → the `drive` backend
   - **OneDrive** → the `onedrive` backend
   - **Proton Drive** → the `protondrive` backend
   - Or any other of rclone's [50+ supported backends](https://rclone.org/overview/)

   This is fully interactive (credentials, OAuth flows, 2FA) — don't attempt to script around it. Repeat for additional remotes if the user wants more than one offsite copy.

   Once configured, set `ENCRYPTED_BACKUP_RCLONE_REMOTES` to a space-separated list of the remote name(s) chosen (e.g. `export ENCRYPTED_BACKUP_RCLONE_REMOTES="gdrive onedrive"` in their shell profile).

Verify afterward with plain read-only commands (`scripts/backup.sh check`, `rclone listremotes`) — don't ask the user to paste secrets back to you.

## The helper script

All setup/run/status/restore logic lives in `scripts/backup.sh` — read it once with the Read tool before first use so you know exactly what it does. It is idempotent and safe to run via the Bash tool directly (it never prints the restic passphrase; it writes it straight to a 600-permission file).

```
scripts/backup.sh check                                # report OS, tools, and remote/drive status
scripts/backup.sh setup <target_dir> [name] [options]   # register + init a new target (options below)
scripts/backup.sh run [name|--all]                      # back up one or all targets (default: --all)
scripts/backup.sh status [name|--all]                   # show last-snapshot time per target
scripts/backup.sh restore-test <name> <dest_dir>        # restore latest snapshot into dest_dir
scripts/backup.sh list                                  # list registered targets
```

Run `scripts/backup.sh check` first in any new environment — it reports the detected OS, which required tools are present/missing (with platform-specific install hints), which rclone remotes are configured, and whether the local-drive mirror is connected.

State (outside any target dir, so nothing backs itself up):
- Registry: `~/Backups/registry.json`
- Repos: `~/Backups/restic-repos/<name>/`
- Passphrases: `~/.config/claude-encrypted-backup/secrets/<name>.pass` (chmod 600 where the filesystem supports it, generated by the script, never displayed by it)
- Logs: `~/Backups/logs/<name>.log`

## Adding a new target directory

1. Run `scripts/backup.sh check` and confirm all required tools are present and at least one offsite remote is configured (or knowingly proceed local-only for now).
2. `scripts/backup.sh setup <target_dir>` — derives a name from the directory basename unless one is given.
3. Tell the user to copy the newly generated passphrase into their password manager **now**, in their own terminal:
   ```
   cat ~/.config/claude-encrypted-backup/secrets/<name>.pass
   ```
   Explain why this step is non-optional: the passphrase lives only in that local file. If this machine's disk fails, both the working directory *and* that file are gone — the only way to decrypt an offsite copy afterward is a passphrase saved somewhere durable and separate (password manager, or a physical copy with other important paperwork).
4. `scripts/backup.sh run <name>` to take the first snapshot and push it offsite.
5. `scripts/backup.sh restore-test <name> <scratch_dir>` once, into a throwaway directory, and spot-check the restored files against the original — an untested backup is not a backup. Note: restic restores under the *full absolute source path*, so the restored files land at `<scratch_dir>/<original absolute path>`, not directly in `<scratch_dir>` — e.g. `diff -rq <original> <scratch_dir><original> --exclude=.git`.

### Code repositories (per-target options)

The defaults suit document folders: pending changes are auto-committed before each backup, and `.git` is excluded from snapshots. Both are wrong for a code repo, especially one with no git remote: auto-commits pollute project history, and excluding `.git` loses the commit history and any Git LFS objects. `setup` accepts per-target options, stored in the registry entry, that change this for one target only:

- `--include-git`: snapshot `.git` as well (history plus `.git/lfs` objects)
- `--no-auto-commit`: never commit on the user's behalf
- `--exclude PATTERN` (repeatable): extra restic excludes, e.g. regenerable build caches

Example: `scripts/backup.sh setup ~/code/my-game --include-git --no-auto-commit --exclude game/.godot --exclude game/builds`. Entries without these fields keep the default behavior.

## Routine use

- Manual run: `scripts/backup.sh run --all` (or a single name).
- Reading a run's result: every mirror is verified with `rclone check` after syncing. Trust the final line: `backup complete: <name>` means the local snapshot and every configured mirror are confirmed; `backup FAILED: <name> — ...` (with a non-zero exit) names the failed step or unverified mirror. Stray rclone `ERROR`/`NOTICE` lines above a `backup complete` are retries rclone recovered from (e.g. a transient Proton `401 Invalid access token`), not failures. With `--all`, a failing target doesn't stop the rest; the run ends with a summary of the targets that failed.
- Checking status: `scripts/backup.sh status --all` reports the last snapshot time and drive/remote mirror state per target — use this if the user asks "is my backup current?"
- When the user adds a new sensitive directory later, just repeat "Adding a new target directory" above.

## Scheduled automation

Set-and-forget automation needs an OS-native scheduler — this task is inherently local-only (a cloud-scheduled agent has no access to this machine's mounted drives, rclone config, or passphrase files). Templates for all three platforms are in `scripts/schedule/`:

- **Linux**: `scripts/schedule/linux-systemd/` — a `systemd --user` service + weekly timer (Sundays 03:00, `Persistent=true` so a missed run fires at next boot/login). Edit the `ExecStart=` path in the `.service` file first, then:
  ```
  ! mkdir -p ~/.config/systemd/user
  ! cp scripts/schedule/linux-systemd/*.service scripts/schedule/linux-systemd/*.timer ~/.config/systemd/user/
  ! systemctl --user daemon-reload
  ! systemctl --user enable --now encrypted-backup.timer
  ! loginctl enable-linger $USER   # so it still runs while logged out
  ```
  Check it: `systemctl --user list-timers encrypted-backup.timer`, `journalctl --user -u encrypted-backup.service -n 60`. **Common gotcha**: `systemd --user` services get a minimal `PATH` — if restic/rclone/jq were installed somewhere non-standard (Homebrew/linuxbrew, a manual install), the `Environment=PATH=...` line in the `.service` file needs to include that location.
- **macOS**: `scripts/schedule/macos-launchd/com.claude.encrypted-backup.plist` — a `launchd` agent, same weekly schedule. Edit the script path inside it first, then:
  ```
  ! cp scripts/schedule/macos-launchd/com.claude.encrypted-backup.plist ~/Library/LaunchAgents/
  ! launchctl load ~/Library/LaunchAgents/com.claude.encrypted-backup.plist
  ```
- **Windows**: `scripts/schedule/windows-task-scheduler/register-task.ps1` — a PowerShell script that registers a weekly Task Scheduler task (via WSL by default, or Git Bash — see comments in the file). Edit `$ScriptPath` first, then run it in an **elevated** PowerShell prompt.

All three are one-time, privileged setup steps — hand them to the user as `!` commands, same as the prerequisites above; don't run scheduler registration through the Bash tool directly.

## Things to get right

- Never `cat`, echo, or otherwise surface a passphrase file's contents yourself — only tell the user the command to run themselves.
- Never run `rclone config`, `sudo`/admin-elevated commands, or anything that needs an interactive credential prompt through the Bash tool — hand it to the user as a `!` command instead.
- If a target directory already has its own git repo (with or without a remote), leave it as-is — don't re-init or touch its remotes.
- The restic `--exclude ".git"` flag in the backup step is intentional: git already has its own local history, no need to duplicate `.git` internals into the restic snapshot.
- `ENCRYPTED_BACKUP_RCLONE_REMOTES` and the local-mirror mount are global settings, not per-target — a user can add or change offsite remotes at any time without re-running `setup` for existing targets.
