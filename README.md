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
  the last run — nothing is re-copied or duplicated. The tracking database
  that makes this work is kept on local disk (`~/Library/Application
  Support/photos-nas-sync/export.db`), not on the NAS share, since SQLite's
  file locking isn't reliable over SMB.
- **Schedule:** runs daily at 3:00 AM, plus once whenever you log in.
- **Tooling:** [osxphotos](https://github.com/RhetTbull/osxphotos) (the
  standard CLI for scripted Photos exports) driven by a macOS launchd agent.

## Requirements

- macOS with the Photos library you want to sync
- `bash` (preinstalled on macOS)
- Network access to `cm5.local`
- One of `pipx`, Homebrew, or `pip3` available so `install.sh` can install
  [osxphotos](https://github.com/RhetTbull/osxphotos)

## Files

| File | Purpose |
|---|---|
| `install.sh` | One-time setup — run this first |
| `uninstall.sh` | Removes the service (see **Uninstalling** below) |
| `mount_nas_share.sh` | Mounts `smb://cm5.local/data` at `/Volumes/data` if not already mounted |
| `sync_photos.sh` | The actual sync: mount check + `osxphotos export` |
| `com.jason.photosnassync.plist` | launchd agent definition (installed to `~/Library/LaunchAgents/`) |

All `.sh` scripts are tracked as executable in this repo, so `./install.sh`
and `./uninstall.sh` work directly; `bash install.sh` also still works.

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
./install.sh
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
- **A run appears to re-copy everything from scratch, including files that
  already made it to the NAS** — this happens if `--update`'s tracking
  database can't be read (e.g. a prior run was interrupted, or SQLite's
  locking failed over SMB), so osxphotos no longer knows those files were
  already exported. Since the destination filenames already exist, osxphotos
  exports them again under new, uniquified names (e.g. `IMG_1234 (1).jpg`)
  instead of overwriting — i.e. duplicates. `sync_photos.sh` now keeps the
  tracking database on local disk
  (`~/Library/Application Support/photos-nas-sync/export.db`) specifically to
  avoid this. If you're on an older copy of this script (no `--exportdb` in
  the `osxphotos export` command), update to the latest version first.
  To recover:
  1. **Stop the run now** — `Ctrl+C` in the terminal it's running in (or, if
     it's the scheduled launchd run, `launchctl stop com.jason.photosnassync`)
     — so it doesn't create more duplicates while you sort this out.
  2. **Try to preserve existing tracking state** before running the updated
     script: if `/Volumes/data/Photos/.osxphotos_export.db` still exists
     from before, copy it to the new local path so osxphotos doesn't start
     from a blank slate (which would just re-trigger the same re-export):
     ```bash
     mkdir -p ~/Library/Application\ Support/photos-nas-sync
     cp "/Volumes/data/Photos/.osxphotos_export.db" \
        ~/Library/Application\ Support/photos-nas-sync/export.db
     ```
     Skip this if that file doesn't exist, or if osxphotos errors trying to
     read it later (delete the copy and let osxphotos create a fresh one).
  3. **Preview before trusting it:** run
     `osxphotos export /Volumes/data/Photos --update --exportdb ~/Library/Application\ Support/photos-nas-sync/export.db --dry-run --verbose`
     once and skim the output. If it lists files that are already correctly
     on the NAS as things it's about to export, the copied database didn't
     carry over the state you wanted — stop and ask before running for real.
  4. **Find and clean up duplicates already created:**
     `find /Volumes/data/Photos -regex '.* ([0-9]+)\..*'` lists them (the
     `IMG_1234 (1).jpg`-style names). Review the list, confirm the
     non-suffixed original is intact for each, then delete, e.g.
     `find /Volumes/data/Photos -regex '.* ([0-9]+)\..*' -delete`.
  5. Once you're satisfied, re-run `~/photos_nas_sync/sync_photos.sh` for
     real; future runs will go back to being a true incremental delta.

## Uninstalling

```bash
cd photos_nas_sync
./uninstall.sh
```

By default this stops and removes the launchd agent and deletes the copied
scripts in `~/photos_nas_sync`. It deliberately leaves alone: anything
already exported to `/Volumes/data/Photos` (your synced photos/videos),
osxphotos itself, and the Keychain entry for the share — none of those are
safe to delete automatically.

Optional flags:
```bash
./uninstall.sh --remove-logs        # also delete the log files
./uninstall.sh --remove-osxphotos   # also uninstall osxphotos
```

To delete the exported photos/videos from the NAS too, do that manually from
Finder/Terminal on `/Volumes/data/Photos` — this is intentionally not
automated since it's not reversible.
