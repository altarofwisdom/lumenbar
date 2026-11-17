#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:/opt/homebrew/bin:$PATH"

echo "🤖 Compilation de LumenBar pour Android (APK)..."
cd "$SCRIPT_DIR"

gradle assembleDebug

OUTPUT_APK="$SCRIPT_DIR/app/build/outputs/apk/debug/app-debug.apk"
TARGET_APK="$SCRIPT_DIR/../LumenBar.apk"

if [ -f "$OUTPUT_APK" ]; then
    cp "$OUTPUT_APK" "$TARGET_APK"
    cp "$OUTPUT_APK" "$SCRIPT_DIR/LumenBar.apk"
    echo "✅ APK généré avec succès :"
    echo "   -> $TARGET_APK"
    echo "   -> $SCRIPT_DIR/LumenBar.apk"
    ls -lh "$TARGET_APK"

    # Exécution d'un hook post-build local optionnel (ex: distribution, adb, etc.)
    if [ -x "$SCRIPT_DIR/post-build.local.sh" ]; then
        "$SCRIPT_DIR/post-build.local.sh" "$TARGET_APK"
    fi
else
    echo "❌ Erreur : APK introuvable dans $OUTPUT_APK"
    exit 1
fi
