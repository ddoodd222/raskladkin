#!/bin/zsh
# Собирает Раскладкин.app и ставит в /Applications. Запуск: ./build.sh
set -e
cd "$(dirname "$0")"

APP_NAME="Раскладкин"
BUNDLE_ID="ru.tokarev.raskladkin"
EXE="Raskladkin"
VERSION="1.0"

# Обход поломки в Command Line Tools: старый module.modulemap дублирует bridging.modulemap.
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
FLAGS=()
if [ -f "$STALE" ] && [ -f "${STALE%/*}/bridging.modulemap" ]; then
  mkdir -p .build
  : > .build/empty.modulemap
  printf '{ "version": 0, "roots": [ { "name": "%s", "type": "file", "external-contents": "%s/.build/empty.modulemap" } ] }\n' "$STALE" "$PWD" > .build/overlay.yaml
  FLAGS=(-vfsoverlay "$PWD/.build/overlay.yaml")
fi

echo "→ Компилирую…"
mkdir -p .build
BIN=".build/$EXE"
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 "${FLAGS[@]}" \
  -framework AppKit -framework Carbon -framework ServiceManagement \
  Sources/Raskladkin/*.swift -o "$BIN"

echo "→ Собираю приложение…"
OUT="dist/$APP_NAME.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp "$BIN" "$OUT/Contents/MacOS/$EXE"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
mkdir -p "$OUT/Contents/Resources"
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT"

echo "→ Устанавливаю…"
pkill -x "$EXE" 2>/dev/null || true
sleep 0.5
DEST="/Applications/$APP_NAME.app"
if ! { rm -rf "$DEST" 2>/dev/null && cp -R "$OUT" "$DEST" 2>/dev/null; }; then
  mkdir -p "$HOME/Applications"
  DEST="$HOME/Applications/$APP_NAME.app"
  rm -rf "$DEST"
  cp -R "$OUT" "$DEST"
fi
# Подпись без сертификата меняется при каждой сборке, поэтому macOS забывает права. Сбрасываем, чтобы спросил заново.
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
open "$DEST"
echo "✓ Готово: $DEST"
