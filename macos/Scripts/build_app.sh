#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="knowledge compiler"
VERSION="1.0.0-beta"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "=== building knowledge compiler v$VERSION ==="

swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/KnowledgeCompiler"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/KnowledgeCompiler"
cp -R "$BIN_DIR/KnowledgeCompiler_KnowledgeCompiler.bundle" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>KnowledgeCompiler</string>
    <key>CFBundleIdentifier</key><string>com.stevenjackson.knowledge-compiler</string>
    <key>CFBundleName</key><string>knowledge compiler</string>
    <key>CFBundleDisplayName</key><string>knowledge compiler</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"

echo "built → $APP"

DESKTOP_APPS="$HOME/Desktop/APPS/DEVELOPMENT"
mkdir -p "$DESKTOP_APPS"

TIMESTAMP="$(date +%Y%m%d_%H%M)"
ZIP_NAME="knowledge-compiler_v${VERSION}_${TIMESTAMP}.zip"
ZIP_PATH="$DESKTOP_APPS/$ZIP_NAME"

rm -f "$DESKTOP_APPS"/knowledge-compiler_v*.zip

cd "$DIST"
zip -rq "$ZIP_PATH" "$APP_NAME.app"
cd ..

echo "packaged → $ZIP_PATH"
echo ""
echo "=== done: knowledge compiler v$VERSION ==="
