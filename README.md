
<a href="https://buymeacoffee.com/weaverb" target="_blank">
  <img src=".github/imgs/blue-button.png" alt="Buy me a coffee" height="35">
</a>

# Encrypted Backup — a Claude Code skill

A [Claude Code](https://claude.com/claude-code) skill (packaged as a plugin) that sets up real, encrypted 3-2-1 disaster-recovery backups for sensitive personal directories — financial records, health records, estate/legal documents, or anything else worth protecting — **without any plaintext ever leaving your machine**.

- **3-2-1**: 3 copies (working directory, a local encrypted repo, an offsite copy) · 2 media (internal disk + an optional second local drive) · 1 offsite (your choice of cloud remote)
- **Encrypted before it leaves**: built on [restic](https://restic.net) — data is encrypted and deduplicated locally before [rclone](https://rclone.org) ever touches it, so no cloud provider (or Claude) ever sees plaintext
- **Cross-platform**: Linux, macOS, and Windows (via Git Bash or WSL)
- **Cloud-agnostic**: Google Drive, OneDrive, Proton Drive, or any of rclone's 50+ supported backends — pick one or several

## Install

**Option 1 — as a Claude Code plugin (recommended):**

```
/plugin marketplace add weaverb/claude-encrypted-backup
/plugin install encrypted-backup@weaverb-encrypted-backup
```

**Option 2 — manually**, if you'd rather not add a marketplace: clone this repo and copy (or symlink) `skills/encrypted-backup/` into your `~/.claude/skills/` directory.

## Use

Once installed, just ask Claude in a normal conversation:

> "Set up an encrypted backup for my ~/Documents/Taxes folder"

> "Is my backup up to date?"

> "Restore my backup"

Claude will walk through the one-time prerequisites (installing `restic`/`rclone`/`jq`, configuring a cloud remote) as interactive steps you run yourself — see [`skills/encrypted-backup/SKILL.md`](skills/encrypted-backup/SKILL.md) for the full design, the exact commands, and how automation/scheduling works on each platform.

## Backing up multiple folders

This isn't limited to one directory — register as many as you want, each tracked and encrypted independently. A real-world setup might look like:

> "Set up encrypted backups for ~/Documents/Taxes, ~/Documents/Medical, and ~/Documents/Legal"

Each becomes its own named target with its own restic repo and its own passphrase, but they all share the same offsite remote(s) and local-mirror drive — you configure those once, not per folder. From then on:

- **"Back up everything"** → `scripts/backup.sh run --all` snapshots every registered folder in one pass. This is what a weekly scheduled run (see [Scheduled automation](skills/encrypted-backup/SKILL.md#scheduled-automation)) should point at, so newly-added folders are picked up automatically without editing the schedule.
- **"Is everything backed up?"** → `scripts/backup.sh status --all` reports the last snapshot time and offsite/local-mirror state for every target at a glance.
- **"What am I backing up?"** → `scripts/backup.sh list` shows every registered folder and where it lives.
- Adding a folder later is the same one-liner as the first: "back up my ~/Projects/NewThing folder too" — no need to touch anything already set up.

## Why trust this with sensitive data?

- The passphrase protecting each backup never leaves your machine and is never displayed by the tooling — you copy it into your own password manager.
- Nothing is sent anywhere until it's already been encrypted locally by restic. Proton Drive, Google Drive, and OneDrive (or wherever you point it) only ever receive opaque encrypted blobs.
- The whole design and the actual script are readable — nothing here is a black box. Read `skills/encrypted-backup/scripts/backup.sh` yourself before trusting it with anything.

## License

MIT — see [LICENSE](LICENSE).
