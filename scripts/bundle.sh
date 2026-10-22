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
cp Resources/AppIcon.png Resources/AppIcon.icns "$APP/Contents/Resources/"
# Ad-hoc signature: enough for SMAppService on this Mac. Developer ID + notarization needed to distribute.
# Folders like ~/Desktop (iCloud/File Provider) tag files with xattrs that codesign rejects.
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  DEST=~/Applications/"AdaptaPE AI Tracker.app"
  mkdir -p ~/Applications
  RUNNING="$DEST/Contents/MacOS/AdaptaPEAITracker"
  RUNNING_PATTERN=$(printf '%s\n' "$RUNNING" | /usr/bin/sed 's/[][\\.^$*+?(){}|]/\\&/g')
  pkill -f -x "$RUNNING_PATTERN" || true
  # `open` fails with -600 if the old instance is still shutting down.
  while pgrep -f -x "$RUNNING_PATTERN" >/dev/null; do sleep 0.2; done
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  for attempt in {1..5}; do
    if open "$DEST"; then
      echo "Installed $DEST"
      exit 0
    fi
    sleep 0.5
  done
  exit 1
fi
