#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="算力码表"
VERSION="${VERSION:-0.1.0}"
ZIP_PATH="$ROOT_DIR/dist/SuanliMabiao-macOS-$VERSION.zip"
OPEN_APP_AFTER_PACKAGE="${OPEN_APP_AFTER_PACKAGE:-1}"

cd "$ROOT_DIR"

OPEN_APP="$OPEN_APP_AFTER_PACKAGE" ./script/build_and_run.sh
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$ROOT_DIR/dist/$APP_NAME.app" "$ZIP_PATH"

echo "Release archive: $ZIP_PATH"
