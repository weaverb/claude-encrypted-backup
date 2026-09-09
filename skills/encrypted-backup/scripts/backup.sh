#!/usr/bin/env bash
# encrypted-backup skill helper
#
# Implements a 3-2-1 backup for sensitive local directories:
#   Copy 1: the working directory itself
#   Copy 2: local git history (text/markdown/json) + a local restic
#           encrypted, deduplicated snapshot repo (handles binaries too),
#           optionally mirrored onto a second local drive
#           — the "2nd medium" copy
#   Copy 3: that same restic repo mirrored to one or more offsite cloud
#           remotes via rclone (Google Drive, OneDrive, Proton Drive, or
#           any other rclone-supported backend) — restic already encrypts
#           everything before rclone ever touches it, so no destination
#           ever sees plaintext.
#
# Cross-platform: Linux and macOS run this natively; on Windows, run it
# under Git Bash or WSL (see the skill's SKILL.md for setup notes).
#
# Subcommands:
#   check                             report detected OS, tool/remote status
#   setup <target_dir> [name]        register + initialize a new target
#   run   [name|--all]               back up one or all registered targets
#   status [name|--all]              show registry + last-snapshot info
#   restore-test <name> <dest_dir>   restore latest snapshot into dest_dir
#   list                             list registered targets
#
# State lives outside any of the target dirs so it never gets backed up
# into itself:
#   registry:   ~/Backups/registry.json
#   repos:      ~/Backups/restic-repos/<name>/
#   passphrase: ~/.config/claude-encrypted-backup/secrets/<name>.pass  (chmod 600)
#   logs:       ~/Backups/logs/<name>.log
#
# Configuration (environment variables, all optional):
#   ENCRYPTED_BACKUP_RCLONE_REMOTES        space-separated rclone remote
#                                           names to mirror offsite, e.g.
#                                           "gdrive onedrive proton" — each
#                                           must already exist in
#                                           `rclone listremotes`. Skipped
#                                           gracefully (with a warning) if
#                                           unset or empty.
#   ENCRYPTED_BACKUP_RCLONE_PATH           base path under each remote
#                                           (default: ClaudeBackups)
#   ENCRYPTED_BACKUP_LOCAL_MIRROR_MOUNT    mount point of a second local
#                                           drive for the "2nd medium"
#                                           copy — e.g. /media/you/backup
#                                           (Linux), /Volumes/Backup
#                                           (macOS), /d (Windows Git
#                                           Bash), /mnt/d (WSL). Skipped
#                                           gracefully if unset or the
#                                           drive isn't connected.
#   ENCRYPTED_BACKUP_LOCAL_MIRROR_SUBDIR   subdirectory under that mount
#                                           (default: ClaudeBackups)

set -euo pipefail

# ---------------------------------------------------------------------------
# OS detection — informs prerequisite messaging and the mount-check fallback.
# ---------------------------------------------------------------------------
detect_os() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux*)   echo "linux" ;;
    Darwin*)  echo "macos" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *)        echo "unknown" ;;
  esac
}
OS_KIND="$(detect_os)"

BACKUPS_ROOT="$HOME/Backups"
REPOS_ROOT="$BACKUPS_ROOT/restic-repos"
LOGS_ROOT="$BACKUPS_ROOT/logs"
SECRETS_ROOT="$HOME/.config/claude-encrypted-backup/secrets"
REGISTRY="$BACKUPS_ROOT/registry.json"
RCLONE_REMOTES="${ENCRYPTED_BACKUP_RCLONE_REMOTES:-}"
RCLONE_BASE_PATH="${ENCRYPTED_BACKUP_RCLONE_PATH:-ClaudeBackups}"
LOCAL_MIRROR_MOUNT="${ENCRYPTED_BACKUP_LOCAL_MIRROR_MOUNT:-}"
LOCAL_MIRROR_SUBDIR="${ENCRYPTED_BACKUP_LOCAL_MIRROR_SUBDIR:-ClaudeBackups}"

mkdir -p "$REPOS_ROOT" "$LOGS_ROOT" "$SECRETS_ROOT"
chmod 700 "$SECRETS_ROOT" 2>/dev/null || true   # chmod is a no-op on some Windows filesystems
[ -f "$REGISTRY" ] || echo '[]' > "$REGISTRY"

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Portability helpers
# ---------------------------------------------------------------------------

# Random passphrase generation: prefer openssl, fall back to /dev/urandom
# (both are present on Linux/macOS and on Windows under Git Bash or WSL).
gen_passphrase() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32
  elif [ -r /dev/urandom ]; then
    head -c 32 /dev/urandom | base64
  else
    die "Neither 'openssl' nor /dev/urandom is available to generate a passphrase. Install openssl and retry."
  fi
}

# "Is a second local drive connected at this path?" — `mountpoint` is
# Linux-only (util-linux). macOS and Windows fall back to "does the
# directory exist and have something in it", which is a weaker check
# (it can't distinguish a real mount from an empty local folder with the
# same name) but is the most portable signal available without adding a
# platform-specific dependency.
is_mounted() {
  local dir="$1"
  [ -n "$dir" ] || return 1
  case "$OS_KIND" in
    linux)
      if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$dir" 2>/dev/null
        return $?
      fi
      ;;
  esac
  [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]
}

# `column -t` isn't guaranteed present (missing on some minimal Windows
# Git Bash installs). Fall back to a plain padded printf table.
print_table() {
  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t'
  else
    awk -F'\t' '{printf "%-24s %s\n", $1, $2}'
  fi
}

install_hint() {
  case "$OS_KIND" in
    linux)
      echo "Linux: use your distro's package manager, e.g. one of:"
      echo "    sudo dnf install -y restic rclone jq       # Fedora/RHEL/Bazzite"
      echo "    sudo apt install -y restic rclone jq       # Debian/Ubuntu"
      echo "    sudo pacman -S restic rclone jq             # Arch"
      ;;
    macos)
      echo "macOS: via Homebrew:"
      echo "    brew install restic rclone jq"
      ;;
    windows)
      echo "Windows (in Git Bash or WSL):"
      echo "    winget install restic.restic rclone.rclone jqlang.jq   # winget"
      echo "    # or, inside WSL, use the Linux instructions for your WSL distro"
      ;;
    *)
      echo "Install restic, rclone, and jq for your platform — see:"
      echo "    https://restic.net  https://rclone.org  https://jqlang.org"
      ;;
  esac
}

require_tools() {
  local missing=()
  for t in git restic rclone jq; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing required tool(s): ${missing[*]}" >&2
    install_hint >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Registry helpers
# ---------------------------------------------------------------------------

entry_for() {
  jq -c --arg n "$1" '.[] | select(.name == $n)' "$REGISTRY"
}

all_names() {
  jq -r '.[].name' "$REGISTRY"
}

cmd_list() {
  if [ "$(jq 'length' "$REGISTRY")" = "0" ]; then
    echo "No targets registered yet. Use: backup.sh setup <target_dir>"
    return
  fi
  jq -r '.[] | "\(.name)\t\(.target)"' "$REGISTRY" | print_table
}

cmd_check() {
  echo "== encrypted-backup: environment check =="
  echo "OS detected:      $OS_KIND  (uname -s: $(uname -s 2>/dev/null || echo '?'))"
  echo
  echo "-- required tools --"
  for t in git restic rclone jq; do
    if command -v "$t" >/dev/null 2>&1; then
      echo "  [ok]      $t  ($(command -v "$t"))"
    else
      echo "  [missing] $t"
    fi
  done
  if ! command -v openssl >/dev/null 2>&1; then
    echo "  [note]    openssl not found — will fall back to /dev/urandom for passphrases"
  fi
  echo
  echo "-- offsite cloud remotes --"
  if command -v rclone >/dev/null 2>&1; then
    local configured
    configured="$(rclone listremotes 2>/dev/null || true)"
    if [ -z "$configured" ]; then
      echo "  No rclone remotes configured yet. Run: rclone config"
      echo "  (supports Google Drive, OneDrive, Proton Drive, and many others)"
    else
      echo "  Configured remotes:"
      echo "$configured" | sed 's/^/    /'
    fi
    if [ -z "$RCLONE_REMOTES" ]; then
      echo "  ENCRYPTED_BACKUP_RCLONE_REMOTES is not set — offsite mirroring will be skipped until it is."
    else
      echo "  ENCRYPTED_BACKUP_RCLONE_REMOTES = $RCLONE_REMOTES"
    fi
  else
    echo "  rclone not installed — see tool check above."
  fi
  echo
  echo "-- second local drive (the '2nd medium' copy) --"
  if [ -z "$LOCAL_MIRROR_MOUNT" ]; then
    echo "  ENCRYPTED_BACKUP_LOCAL_MIRROR_MOUNT is not set — local-drive mirroring will be skipped."
    echo "  Example values: /media/you/BackupDrive (Linux), /Volumes/BackupDrive (macOS), /d (Windows Git Bash)"
  elif is_mounted "$LOCAL_MIRROR_MOUNT"; then
    echo "  $LOCAL_MIRROR_MOUNT — connected"
  else
    echo "  $LOCAL_MIRROR_MOUNT — configured but not currently connected/detected"
  fi
  echo
  echo "-- registered targets --"
  cmd_list
}

cmd_setup() {
  require_tools
  local target="$1"
  local name="${2:-}"
  [ -d "$target" ] || die "Directory not found: $target"
  target="$(cd "$target" && pwd)"
  name="${name:-$(basename "$target" | tr '[:upper:] ' '[:lower:]-')}"

  if [ -n "$(entry_for "$name")" ]; then
    die "A target named '$name' is already registered. Pick another name or edit $REGISTRY directly."
  fi

  local repo="$REPOS_ROOT/$name"
  local passfile="$SECRETS_ROOT/$name.pass"

  echo "==> Registering '$name' -> $target"

  # 1. Local git history (no remote — stays on this machine only)
  if ! git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "==> git init (local only, no remote) in $target"
    git -C "$target" init -q
    git -C "$target" add -A
    git -C "$target" -c user.email="backup@localhost" -c user.name="encrypted-backup" \
      commit -q -m "Initial commit (encrypted-backup skill setup)" || true
  else
    echo "==> $target is already a git repo, leaving it as-is"
  fi

  # 2. Local restic repo with a freshly generated passphrase.
  #    The passphrase is written straight to a 600-perm file and never
  #    printed — copy it into your password manager before you need it.
  if [ ! -f "$passfile" ]; then
    echo "==> Generating restic passphrase -> $passfile (not displayed)"
    umask 077
    gen_passphrase > "$passfile"
    chmod 600 "$passfile" 2>/dev/null || true
  fi

  if [ ! -d "$repo" ] || [ ! -f "$repo/config" ]; then
    echo "==> Initializing restic repo at $repo"
    mkdir -p "$repo"
    restic -r "$repo" --password-file "$passfile" init
  else
    echo "==> restic repo already initialized at $repo"
  fi

  # 3. Register (remotes are a global config concern — see
  #    ENCRYPTED_BACKUP_RCLONE_REMOTES — not baked in per-target, so
  #    adding/changing offsite remotes later needs no re-setup).
  tmp="$(mktemp)"
  jq --arg name "$name" --arg target "$target" --arg repo "$repo" \
     --arg passfile "$passfile" \
     '. + [{name:$name, target:$target, repo:$repo, password_file:$passfile}]' \
     "$REGISTRY" > "$tmp"
  mv "$tmp" "$REGISTRY"

  echo "==> Registered. Run 'backup.sh run $name' to take the first snapshot."
  echo "==> IMPORTANT: copy the passphrase into your password manager now:"
  echo "      cat $passfile"
  echo "    (run that yourself — this script won't print it)"
  if [ -z "$RCLONE_REMOTES" ]; then
    echo "==> NOTE: no offsite remote configured (ENCRYPTED_BACKUP_RCLONE_REMOTES is unset)."
    echo "    Backups will stay local-only until you configure at least one. Run 'backup.sh check' for guidance."
  fi
}

backup_one() {
  local name="$1"
  local entry; entry="$(entry_for "$name")"
  [ -n "$entry" ] || die "No such registered target: $name"

  local target repo passfile
  target="$(jq -r '.target' <<<"$entry")"
  repo="$(jq -r '.repo' <<<"$entry")"
  passfile="$(jq -r '.password_file' <<<"$entry")"
  local log="$LOGS_ROOT/$name.log"

  {
    echo "===== $(date -Is 2>/dev/null || date) backup start: $name (OS: $OS_KIND) ====="

    if git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      if [ -n "$(git -C "$target" status --porcelain)" ]; then
        git -C "$target" add -A
        git -C "$target" -c user.email="backup@localhost" -c user.name="encrypted-backup" \
          commit -q -m "Backup snapshot $(date -Is 2>/dev/null || date)"
        echo "git: committed local changes"
      else
        echo "git: no changes to commit"
      fi
    fi

    echo "restic: backing up $target -> $repo"
    restic -r "$repo" --password-file "$passfile" backup "$target" \
      --exclude ".git" --tag auto

    echo "restic: pruning old snapshots (keep 12 weekly / 12 monthly / all last 30 days)"
    restic -r "$repo" --password-file "$passfile" forget \
      --keep-daily 30 --keep-weekly 12 --keep-monthly 12 --prune >/dev/null

    if [ -n "$RCLONE_REMOTES" ]; then
      for remote in $RCLONE_REMOTES; do
        dest="$remote:$RCLONE_BASE_PATH/$name"
        echo "rclone: mirroring $repo -> $dest"
        if ! rclone sync "$repo" "$dest" --fast-list; then
          echo "WARNING: rclone sync to '$remote' failed — check 'rclone listremotes' and connectivity."
        fi
      done
    else
      echo "offsite mirror: skipped — ENCRYPTED_BACKUP_RCLONE_REMOTES is not set"
    fi

    if [ -n "$LOCAL_MIRROR_MOUNT" ] && is_mounted "$LOCAL_MIRROR_MOUNT"; then
      local_dest="$LOCAL_MIRROR_MOUNT/$LOCAL_MIRROR_SUBDIR/$name"
      echo "rclone: mirroring $repo -> $local_dest (local drive)"
      rclone sync "$repo" "$local_dest" --fast-list
    else
      echo "local mirror: skipped (not configured, or drive not connected)"
    fi

    echo "===== $(date -Is 2>/dev/null || date) backup complete: $name ====="
  } | tee -a "$log"
}

cmd_run() {
  require_tools
  local arg="${1:---all}"
  if [ "$arg" = "--all" ]; then
    for n in $(all_names); do backup_one "$n"; done
  else
    backup_one "$arg"
  fi
}

status_one() {
  local name="$1"
  local entry; entry="$(entry_for "$name")"
  [ -n "$entry" ] || die "No such registered target: $name"
  local target repo passfile
  target="$(jq -r '.target' <<<"$entry")"
  repo="$(jq -r '.repo' <<<"$entry")"
  passfile="$(jq -r '.password_file' <<<"$entry")"

  echo "== $name =="
  echo "  target: $target"
  echo "  repo:   $repo"
  if [ -f "$repo/config" ]; then
    local last
    last="$(restic -r "$repo" --password-file "$passfile" snapshots --json 2>/dev/null | jq -r 'last | .time // "never"')"
    echo "  last snapshot: $last"
  else
    echo "  last snapshot: (repo not initialized)"
  fi
  if [ -n "$RCLONE_REMOTES" ]; then
    for remote in $RCLONE_REMOTES; do
      echo "  offsite ($remote): $remote:$RCLONE_BASE_PATH/$name"
    done
  else
    echo "  offsite: not configured (ENCRYPTED_BACKUP_RCLONE_REMOTES unset)"
  fi
  if [ -n "$LOCAL_MIRROR_MOUNT" ] && is_mounted "$LOCAL_MIRROR_MOUNT"; then
    local local_dest="$LOCAL_MIRROR_MOUNT/$LOCAL_MIRROR_SUBDIR/$name"
    if [ -d "$local_dest" ]; then
      echo "  local drive mirror: present ($local_dest)"
    else
      echo "  local drive mirror: drive connected, not yet synced"
    fi
  else
    echo "  local drive mirror: not configured or drive not connected"
  fi
}

cmd_status() {
  require_tools
  local arg="${1:---all}"
  if [ "$arg" = "--all" ]; then
    for n in $(all_names); do status_one "$n"; done
  else
    status_one "$arg"
  fi
}

cmd_restore_test() {
  require_tools
  local name="$1" dest="$2"
  local entry; entry="$(entry_for "$name")"
  [ -n "$entry" ] || die "No such registered target: $name"
  local repo passfile
  repo="$(jq -r '.repo' <<<"$entry")"
  passfile="$(jq -r '.password_file' <<<"$entry")"
  mkdir -p "$dest"
  restic -r "$repo" --password-file "$passfile" restore latest --target "$dest"
  echo "Restored latest snapshot of '$name' into: $dest"
}

case "${1:-}" in
  check)        cmd_check ;;
  setup)        shift; cmd_setup "$@" ;;
  run)          shift; cmd_run "$@" ;;
  status)       shift; cmd_status "$@" ;;
  restore-test) shift; cmd_restore_test "$@" ;;
  list)         cmd_list ;;
  *)
    cat >&2 <<EOF
Usage: backup.sh <check|setup|run|status|restore-test|list> [args]

  check                             report detected OS, tool/remote status
  setup <target_dir> [name]        register + initialize a new target
  run   [name|--all]                back up one or all registered targets (default: --all)
  status [name|--all]               show last-snapshot info (default: --all)
  restore-test <name> <dest_dir>    restore latest snapshot into dest_dir
  list                              list registered targets
EOF
    exit 1
    ;;
esac
