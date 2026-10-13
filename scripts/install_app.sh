#!/bin/bash
# Builds a release Zap.app bundle and installs it into /Applications, so it
# runs as a normal standalone app (Spotlight/Dock/Finder launchable) instead
# of only from .build/ inside the project checkout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Zap"
DEST="/Applications/$APP_NAME.app"

echo "==> building release bundle"
"$ROOT_DIR/scripts/build_app.sh" release

SRC="$ROOT_DIR/.build/$APP_NAME.app"
if [ ! -d "$SRC" ]; then
  echo "error: built bundle not found at $SRC" >&2
  exit 1
fi

if [ -d "$DEST" ]; then
  echo "==> removing previous install at $DEST"
  rm -rf "$DEST"
fi

echo "==> installing to $DEST"
cp -R "$SRC" "$DEST"

echo "==> done: $DEST"
