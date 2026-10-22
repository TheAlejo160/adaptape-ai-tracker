#!/bin/zsh
# Builds a release .app bundle. `scripts/bundle.sh install` also copies it to ~/Applications and launches it.
set -euo pipefail
cd "${0:A:h}/.."

APP="build/AdaptaPE AI Tracker.app"

swift build -c release --scratch-path /tmp/aitracker-build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --scratch-path /tmp/aitracker-build --show-bin-path)/AdaptaPEAITracker" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"
cp LICENSE docs/LICENSE-LimitBar.txt "$APP/Contents/Resources/"
# Ad-hoc signature: enough for SMAppService on this Mac. Developer ID + notarization needed to distribute.
# Folders like ~/Desktop (iCloud/File Provider) tag files with xattrs that codesign rejects.
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  DEST=~/Applications/"AdaptaPE AI Tracker.app"
  mkdir -p ~/Applications
  pkill -x AdaptaPEAITracker || true
  # `open` fails with -600 if the old instance is still shutting down.
  while pgrep -x AdaptaPEAITracker >/dev/null; do sleep 0.2; done
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed $DEST"
fi
