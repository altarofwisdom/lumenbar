#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$HOME/Applications/LumenBar.app"

echo "🔨 Compilation de LumenBar.app..."
swiftc -O -parse-as-library \
    "$SCRIPT_DIR/Sources/Localization.swift" \
    "$SCRIPT_DIR/Sources/AutoLightEngine.swift" \
    "$SCRIPT_DIR/Sources/LampController.swift" \
    "$SCRIPT_DIR/Sources/LumenBarMenuView.swift" \
    "$SCRIPT_DIR/Sources/main.swift" \
    -o /tmp/LumenBar_bin

echo "📦 Assemblage du bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp /tmp/LumenBar_bin "$APP_DIR/Contents/MacOS/LumenBar"
chmod +x "$APP_DIR/Contents/MacOS/LumenBar"

cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$SCRIPT_DIR/Resources/lumenbar.py" "$APP_DIR/Contents/Resources/lumenbar.py"
chmod +x "$APP_DIR/Contents/Resources/lumenbar.py"
ln -sf lumenbar.py "$APP_DIR/Contents/Resources/gdansk.py"

echo "✍️ Signature locale..."
codesign --force --deep --sign - "$APP_DIR"
rm -f /tmp/LumenBar_bin

echo "✅ LumenBar.app est prêt dans $APP_DIR"
