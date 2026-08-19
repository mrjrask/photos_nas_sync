#!/bin/bash
# Incrementally exports every photo/video in the Photos library to the cm5
# NAS share, organized into one folder per capture day (YYYY-MM-DD).
#
# Why per-day and not per-"Moment/Event": osxphotos (the export tool this
# script relies on) does not expose Photos' Moments/Events clustering as a
# stable, documented identifier -- and that clustering can be re-computed by
# Photos over time, which would silently move/duplicate files across runs of
# an incremental sync. Per-day folders based on the fixed capture date are
# stable, which is required for --update to work correctly. This matches the
# explicit fallback you specified.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_ROOT="/Volumes/data/Photos"
LOG_FILE="$HOME/Library/Logs/photos-nas-sync.log"
LOG_TAG="[photos-nas-sync]"

# The --update export database is kept on LOCAL disk, not inside $DEST_ROOT.
# osxphotos' database is a SQLite file, and SQLite's locking doesn't work
# reliably over SMB -- if the database lives on the NAS, a run that gets
# interrupted (or just flaky SMB locking) can leave it unreadable/stale, so
# the next run can't tell what was already exported and re-exports
# everything, creating "(1)"-suffixed duplicates next to the originals.
# Keeping it locally makes --update's progress tracking reliable regardless
# of the network share's behavior.
EXPORT_DB_DIR="$HOME/Library/Application Support/photos-nas-sync"
EXPORT_DB="$EXPORT_DB_DIR/export.db"

mkdir -p "$(dirname "$LOG_FILE")"

# Local (non-network) lock so a launchd-triggered run and a manual run can
# never overlap. Two processes racing to create $DEST_ROOT on the SMB share
# at the same instant is what caused the "mkdir: Operation not permitted"
# error during install -- this lock makes that impossible going forward.
#
# The lock dir's pid file lets a later run tell a genuinely-still-running
# sync (plausible for hours on an initial 1TB+ export) apart from a stale
# lock left by a run that was killed (crash, force-quit, kill -9) before its
# EXIT trap could fire -- without this check, a stale lock would silently
# block every future scheduled run forever.
LOCK_DIR="/tmp/photos-nas-sync.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_PID_FILE"
    return 0
  fi
  local existing_pid
  existing_pid="$(cat "$LOCK_PID_FILE" 2>/dev/null || true)"
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    return 1
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG Removing stale lock at $LOCK_DIR (owner pid ${existing_pid:-unknown} not running)." >> "$LOG_FILE"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  echo $$ > "$LOCK_PID_FILE"
}

if ! acquire_lock; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG Another sync is already running (lock held at $LOCK_DIR). Exiting." >> "$LOG_FILE"
  exit 0
fi
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT

# Rotate the log before this run if it's grown large -- --verbose on a
# library this size produces a lot of output, and nothing else trims it.
LOG_MAX_BYTES=$((100 * 1024 * 1024))
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
  mv -f "$LOG_FILE" "$LOG_FILE.1"
fi

exec >> "$LOG_FILE" 2>&1

echo "===== $(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG run start ====="

# 1. Make sure the NAS share is mounted before we try to write anything to it.
if ! "$SCRIPT_DIR/mount_nas_share.sh"; then
  echo "$LOG_TAG Aborting: NAS share not reachable/mounted. Will retry next scheduled run."
  exit 1
fi

if ! mkdir -p "$DEST_ROOT"; then
  echo "$LOG_TAG ERROR: could not create $DEST_ROOT."
  echo "$LOG_TAG If this persists (not just a one-off), jason likely lacks write"
  echo "$LOG_TAG permission on /Volumes/data itself -- see README Troubleshooting."
  exit 1
fi

mkdir -p "$EXPORT_DB_DIR"

echo "$LOG_TAG Destination free space: $(df -h "$DEST_ROOT" | awk 'NR==2{print $4}')"

# 2. Locate the osxphotos binary (handles pipx / brew / pip --user installs).
OSXPHOTOS_BIN="$(command -v osxphotos || true)"
if [ -z "$OSXPHOTOS_BIN" ]; then
  for candidate in "$HOME/.local/bin/osxphotos" "/opt/homebrew/bin/osxphotos" "/usr/local/bin/osxphotos"; do
    if [ -x "$candidate" ]; then
      OSXPHOTOS_BIN="$candidate"
      break
    fi
  done
fi

if [ -z "$OSXPHOTOS_BIN" ]; then
  echo "$LOG_TAG ERROR: osxphotos not found on this Mac. Run install.sh first."
  exit 1
fi

echo "$LOG_TAG Using osxphotos at $OSXPHOTOS_BIN"

# 3. Incremental, full-resolution export.
#    --update            only exports items new/changed since the last run
#                         (tracked via --exportdb below) -- this is the
#                         "sync" mechanism, nothing is re-copied or
#                         duplicated on repeat runs.
#    --exportdb           puts the tracking database on LOCAL disk instead of
#                         $DEST_ROOT (see EXPORT_DB comment above) so
#                         --update's state survives flaky SMB locking.
#    --download-missing  forces download of full-resolution originals that
#                         are only iCloud-optimized (not fully on this Mac),
#                         so nothing scaled-down ever lands on the NAS.
#    --directory          "{created.date}" is osxphotos' built-in ISO date
#                         field -> one folder per capture day, e.g. 2026-08-18/
#    --retry 3            osxphotos' own recommendation when exporting to a
#                         NAS: automatically retries a file on transient
#                         network/SMB errors instead of failing the run.
#    (original filenames are kept by default -- no flag needed for that)
EXPORT_CMD=(
  "$OSXPHOTOS_BIN" export "$DEST_ROOT"
  --update
  --exportdb "$EXPORT_DB"
  --download-missing
  --directory "{created.date}"
  --retry 3
  --touch-file
  --verbose
)

# Wrapped in caffeinate so macOS doesn't idle/system-sleep mid-export and
# drop the SMB mount -- this run can take hours (or longer) on an initial
# large library. Note this can't override a closed laptop lid forcing
# clamshell sleep; keep the lid open (or an external display attached) and
# the Mac plugged into power for the initial export.
if command -v caffeinate >/dev/null 2>&1; then
  caffeinate -i -s -m "${EXPORT_CMD[@]}"
else
  "${EXPORT_CMD[@]}"
fi

echo "===== $(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG run end ====="
