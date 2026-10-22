#!/bin/zsh
# Builds a release .app bundle. `scripts/bundle.sh install` also copies it to ~/Applications and launches it.
set -euo pipefail
cd "${0:A:h}/.."

APP="build/AdaptaPE AI Tracker.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/AdaptaPEAITracker" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# Ad-hoc signature: enough for SMAppService on this Mac. Developer ID + notarization needed to distribute.
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  DEST=~/Applications/"AdaptaPE AI Tracker.app"
  mkdir -p ~/Applications
  pkill -x AdaptaPEAITracker || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed $DEST"
fi
