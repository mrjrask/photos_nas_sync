# Photos → cm5 NAS sync

Ongoing service that exports every photo and video in your Mac's Photos
library, full resolution, to the `data` Samba share on `cm5.local`, sorted
into one folder per capture day.

## What it does

- **Destination:** `/Volumes/data/Photos/YYYY-MM-DD/` (one folder per capture
  date, e.g. `2026-08-18/`). Photos' Moments/Events grouping isn't exposed as
  a stable ID by the export tool, so day-based folders are used instead, per
  your fallback instruction — this also keeps incremental syncs reliable
  (files never need to move between folders on a later run).
- **Full resolution:** originals only, never Photos' scaled/preview copies.
  Items that are iCloud-optimized (not fully downloaded to this Mac) are
  force-downloaded before export.
- **Incremental:** each run only exports items that are new or changed since
  the last run — nothing is re-copied or duplicated.
- **Schedule:** runs daily at 3:00 AM, plus once whenever you log in.
- **Tooling:** [osxphotos](https://github.com/RhetTbull/osxphotos) (the
  standard CLI for scripted Photos exports) driven by a macOS launchd agent.

## Files

| File | Purpose |
|---|---|
| `install.sh` | One-time setup — run this first |
| `uninstall.sh` | Removes the service (see **Uninstalling** below) |
| `mount_nas_share.sh` | Mounts `smb://cm5.local/data` at `/Volumes/data` if not already mounted |
| `sync_photos.sh` | The actual sync: mount check + `osxphotos export` |
| `com.jason.photosnassync.plist` | launchd agent definition (installed to `~/Library/LaunchAgents/`) |

## Prerequisite (do this once, before running install.sh)

Connect to the share once via Finder so macOS saves the password in your
Keychain — the scripts read from Keychain and never handle your password
directly:

1. Finder → **Go → Connect to Server** (`Cmd+K`)
2. Enter `smb://cm5.local/data`, sign in as `jason`, and check **"Remember
   this password in my keychain"**.

If this share is already mounted/connected on your Mac today, this is
already done — skip ahead.

## Setup

```bash
cd photos_nas_sync
bash install.sh
```

This installs osxphotos (via pipx, or Homebrew+pipx, or `pip3 --user` as a
fallback), copies the scripts to `~/photos_nas_sync/`, installs and loads the
launchd agent, and runs the first sync immediately.

**Important:** the first run may trigger a macOS permission dialog asking to
allow access to your Photos library. Click **Allow** — if you don't, the
scheduled background runs will fail silently (no GUI dialog can appear when
launchd runs headless).

## Verifying it's working

Check the launchd job is loaded:
```bash
launchctl list | grep photosnassync
```

Check the log after a run:
```bash
tail -50 ~/Library/Logs/photos-nas-sync.log
```

Check files landed on the NAS:
```bash
ls /Volumes/data/Photos/
ls "/Volumes/data/Photos/$(date +%Y-%m-%d)/"
```

Force a run right now without waiting for the schedule:
```bash
~/photos_nas_sync/sync_photos.sh
tail -f ~/Library/Logs/photos-nas-sync.log
```

## Adjusting the schedule

Edit `~/Library/LaunchAgents/com.jason.photosnassync.plist`, change the
`Hour`/`Minute` under `StartCalendarInterval` (or replace it with
`StartInterval` + a number of seconds for "every N hours" instead of once a
day), then reload:

```bash
launchctl unload ~/Library/LaunchAgents/com.jason.photosnassync.plist
launchctl load ~/Library/LaunchAgents/com.jason.photosnassync.plist
```

## Troubleshooting

- **"osxphotos not found"** — re-run `install.sh`, or check
  `~/Library/Python/*/bin` / `~/.local/bin` is on your `PATH`.
- **Mount fails / share unreachable** — the sync simply logs an error and
  exits; it will retry on the next scheduled run. Check `cm5.local` is
  reachable (`ping cm5.local`) and that Keychain has saved credentials for
  it (Keychain Access app → search "cm5").
- **No files exported after the first run** — that's expected; `--update`
  means only *new* items copy on subsequent runs.
- **Permission dialog never appeared / export silently does nothing** — run
  `~/photos_nas_sync/sync_photos.sh` manually from Terminal once so macOS can
  prompt you for Photos access interactively, then check
  System Settings → Privacy & Security → Photos.
- **`mkdir: /Volumes/data/Photos: Operation not permitted`** — this happened
  during initial install because the manual first run and the login-triggered
  launchd run raced to create the folder at the same instant over SMB. Fixed:
  `sync_photos.sh` now uses a local lock file so two runs can never overlap,
  and `install.sh` runs the manual verification pass *before* loading the
  launchd agent. If you still see this error on a clean run (not right after
  install), it means jason genuinely lacks write permission on
  `/Volumes/data` — check Samba's `write list`/permissions for the `data`
  share on cm5, and confirm `touch /Volumes/data/testfile` works from
  Terminal.
- **`Error: No such option '--original-name'`** — that flag doesn't exist in
  current osxphotos (it already preserves original filenames by default);
  it's been removed from `sync_photos.sh`.

## Uninstalling

```bash
cd photos_nas_sync
bash uninstall.sh
```

By default this stops and removes the launchd agent and deletes the copied
scripts in `~/photos_nas_sync`. It deliberately leaves alone: anything
already exported to `/Volumes/data/Photos` (your synced photos/videos),
osxphotos itself, and the Keychain entry for the share — none of those are
safe to delete automatically.

Optional flags:
```bash
bash uninstall.sh --remove-logs        # also delete the log files
bash uninstall.sh --remove-osxphotos   # also uninstall osxphotos
```

To delete the exported photos/videos from the NAS too, do that manually from
Finder/Terminal on `/Volumes/data/Photos` — this is intentionally not
automated since it's not reversible.
