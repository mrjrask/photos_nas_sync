#!/bin/bash
# One-time installer for the Photos -> cm5 NAS sync service.
# Run this once on the Mac that has the Photos library:
#   bash install.sh
set -euo pipefail

INSTALL_DIR="$HOME/photos_nas_sync"
PLIST_LABEL="com.jason.photosnassync"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
SCRIPT_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Installing Photos -> NAS sync =="

echo "-- 1/5 Installing osxphotos (if needed)"
if ! command -v osxphotos >/dev/null 2>&1; then
  if command -v pipx >/dev/null 2>&1; then
    pipx install osxphotos
  elif command -v brew >/dev/null 2>&1; then
    brew install pipx
    pipx ensurepath
    pipx install osxphotos
  else
    python3 -m pip install --user -U osxphotos
    echo "NOTE: if 'osxphotos' isn't found afterwards, add \$HOME/Library/Python/*/bin to your PATH."
  fi
else
  echo "osxphotos already installed: $(command -v osxphotos)"
fi

echo "-- 2/5 Copying scripts to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_SRC_DIR/sync_photos.sh" "$INSTALL_DIR/"
cp "$SCRIPT_SRC_DIR/mount_nas_share.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/sync_photos.sh" "$INSTALL_DIR/mount_nas_share.sh"

echo "-- 3/5 Running first sync now (this can take a while for a large library)"
echo "   macOS may pop up a permission dialog asking to allow access to your"
echo "   Photos library -- click Allow, or scheduled runs will silently fail."
echo "   (Deliberately done BEFORE the launchd agent is installed below, so"
echo "   this manual run can't race with a login-triggered run over SMB.)"
if "$INSTALL_DIR/sync_photos.sh"; then
  echo "First run completed."
else
  echo "First run reported an error -- check $HOME/Library/Logs/photos-nas-sync.log"
  echo "Continuing to install the launchd agent anyway; fix the error above, then re-run:"
  echo "  ~/photos_nas_sync/sync_photos.sh"
fi

echo "-- 4/5 Installing launchd agent"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#/Users/jason#$HOME#g" "$SCRIPT_SRC_DIR/${PLIST_LABEL}.plist" > "$PLIST_DEST"
launchctl unload "$PLIST_DEST" >/dev/null 2>&1 || true
launchctl load "$PLIST_DEST"

echo "-- 5/5 Done."
echo ""
echo "Logs:        $HOME/Library/Logs/photos-nas-sync.log"
echo "Destination: /Volumes/data/Photos/YYYY-MM-DD/"
echo "Schedule:    daily at 03:00, plus once at every login (RunAtLoad)"
echo "Check job:   launchctl list | grep photosnassync"
