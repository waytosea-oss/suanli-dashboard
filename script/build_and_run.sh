#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="算力码表"
OLD_APP_NAMES=("Codex算力宝" "算力余额宝" "Codex 算力浮窗")
EXECUTABLE_NAME="CodexBalance"
BUNDLE_ID="dev.codex.balance-dashboard"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
OPEN_APP="${OPEN_APP:-1}"
WATCHER_DIR="$HOME/Library/Application Support/CodexBalanceDashboard"
BUILD_LOCK="$WATCHER_DIR/build.lock"

cd "$ROOT_DIR"

mkdir -p "$WATCHER_DIR"
touch "$BUILD_LOCK"
trap 'rm -f "$BUILD_LOCK"' EXIT

APP_PIDS="$(pgrep -x "$EXECUTABLE_NAME" 2>/dev/null || true)"
if [[ -n "$APP_PIDS" ]]; then
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    pkill -P "$pid" -f 'codex app-server --listen stdio://' >/dev/null 2>&1 || true
  done <<< "$APP_PIDS"
fi
pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true

swift build -c release --product "$EXECUTABLE_NAME"
BUILD_DIR="$(swift build -c release --show-bin-path)"
BIN_PATH="$BUILD_DIR/$EXECUTABLE_NAME"

rm -rf "$APP_PATH"
for OLD_APP_NAME in "${OLD_APP_NAMES[@]}"; do
  rm -rf "$DIST_DIR/$OLD_APP_NAME.app"
done
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

# SwiftPM 资源包（本地化 .strings 等）：可执行文件在 MacOS/ 下用 Bundle.module 查找，
# 资源包必须与可执行文件同目录
for RESOURCE_BUNDLE in "$BUILD_DIR"/CodexBalanceDashboard_*.bundle; do
  [ -d "$RESOURCE_BUNDLE" ] && cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/MacOS/"
done

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh-Hans</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh-Hans</string>
    <string>zh-Hant</string>
    <string>en</string>
    <string>ja</string>
    <string>ko</string>
    <string>es</string>
    <string>fr</string>
    <string>de</string>
    <string>ru</string>
    <string>pt-BR</string>
  </array>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$APP_PATH" >/dev/null

DESKTOP_LINK="$HOME/Desktop/$APP_NAME.app"
for OLD_APP_NAME in "${OLD_APP_NAMES[@]}"; do
  OLD_DESKTOP_LINK="$HOME/Desktop/$OLD_APP_NAME.app"
  if [[ -L "$OLD_DESKTOP_LINK" ]]; then
    rm "$OLD_DESKTOP_LINK" 2>/dev/null || true
  fi
done
if [[ -L "$DESKTOP_LINK" ]]; then
  CURRENT_DESKTOP_TARGET="$(readlink "$DESKTOP_LINK" 2>/dev/null || true)"
  if [[ "$CURRENT_DESKTOP_TARGET" != "$APP_PATH" ]]; then
    rm "$DESKTOP_LINK" 2>/dev/null || true
  fi
fi
if [[ ! -e "$DESKTOP_LINK" ]]; then
  ln -s "$APP_PATH" "$DESKTOP_LINK" 2>/dev/null || true
fi

LEGACY_RELEASE_DIR="$ROOT_DIR/release/mac-arm64"
LEGACY_APP_LINK="$LEGACY_RELEASE_DIR/$APP_NAME.app"
mkdir -p "$LEGACY_RELEASE_DIR"
for OLD_APP_NAME in "${OLD_APP_NAMES[@]}"; do
  OLD_LEGACY_APP_LINK="$LEGACY_RELEASE_DIR/$OLD_APP_NAME.app"
  if [[ -L "$OLD_LEGACY_APP_LINK" ]]; then
    rm "$OLD_LEGACY_APP_LINK"
  fi
done
if [[ -L "$LEGACY_APP_LINK" ]]; then
  rm "$LEGACY_APP_LINK"
fi
if [[ ! -e "$LEGACY_APP_LINK" ]]; then
  ln -s "$APP_PATH" "$LEGACY_APP_LINK"
fi

if [[ "$OPEN_APP" == "1" ]]; then
  /usr/bin/open -n "$APP_PATH"
  echo "Opened $APP_PATH"
else
  echo "Packaged $APP_PATH"
fi
echo "Desktop shortcut: $DESKTOP_LINK"
echo "Legacy shortcut: $LEGACY_APP_LINK"
