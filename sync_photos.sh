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

# Local (non-network) lock so a launchd-triggered run and a manual run can
# never overlap. Two processes racing to create $DEST_ROOT on the SMB share
# at the same instant is what caused the "mkdir: Operation not permitted"
# error during install -- this lock makes that impossible going forward.
LOCK_DIR="/tmp/photos-nas-sync.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG Another sync is already running (lock held at $LOCK_DIR). Exiting." >> "$LOG_FILE"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

mkdir -p "$(dirname "$LOG_FILE")"
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
#                         (tracked in an export database osxphotos keeps
#                         inside $DEST_ROOT) -- this is the "sync" mechanism,
#                         nothing is re-copied or duplicated on repeat runs.
#    --download-missing  forces download of full-resolution originals that
#                         are only iCloud-optimized (not fully on this Mac),
#                         so nothing scaled-down ever lands on the NAS.
#    --directory          "{created.date}" is osxphotos' built-in ISO date
#                         field -> one folder per capture day, e.g. 2026-08-18/
#    --retry 3            osxphotos' own recommendation when exporting to a
#                         NAS: automatically retries a file on transient
#                         network/SMB errors instead of failing the run.
#    (original filenames are kept by default -- no flag needed for that)
"$OSXPHOTOS_BIN" export "$DEST_ROOT" \
  --update \
  --download-missing \
  --directory "{created.date}" \
  --retry 3 \
  --touch-file \
  --verbose

echo "===== $(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG run end ====="
