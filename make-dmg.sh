#!/bin/zsh
# Собирает dist/Раскладкин-<версия>.dmg с фоном и раскладкой окна. Запуск: ./make-dmg.sh (сначала ./build.sh)
set -e
cd "$(dirname "$0")"
APP_NAME="Раскладкин"
APP="dist/$APP_NAME.app"
[ -d "$APP" ] || { echo "Сначала ./build.sh"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE="dist/dmg"
RW="dist/rw.dmg"
DMG="dist/$APP_NAME-$VERSION.dmg"
VOL="/Volumes/$APP_NAME"

rm -rf "$STAGE" "$RW" "$DMG"; mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Программы"
cp Resources/dmg-bg.tiff "$STAGE/.background/bg.tiff"
cat > "$STAGE/Как установить.txt" <<TXT
Раскладкин $VERSION — чинит текст, набранный не в той раскладке (EN ↔ RU).

1. Перетащи «Раскладкин» в папку «Программы».
2. Запусти. macOS скажет, что не может проверить приложение — это нормально,
   у него нет подписи Apple. Закрой окно и открой:
   Системные настройки → Конфиденциальность и безопасность → внизу «Всё равно открыть».
3. Приложение попросит доступ «Универсальный доступ» — включи его там же.
   Без этого оно не видит, что ты печатаешь.
4. В menubar появится иконка клавиатуры. Всё, работает.

Как пользоваться:
• Выдели неправильный текст и нажми ⌘⇧A — он переведётся в другую раскладку.
  Ничего не выделял — исправится слово, которое ты только что напечатал.
• Автомат: после трёх подряд слов не в той раскладке сам всё перепечатает.
• Настройки, порог, хоткей и выключение — в меню по клику на иконку.
TXT

# 1) образ с правом записи, чтобы Finder мог сохранить раскладку окна
[ -d "$VOL" ] && hdiutil detach "$VOL" -quiet || true
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
hdiutil attach "$RW" -readwrite -noverify -noautoopen >/dev/null
sleep 1

# 2) раскладка окна: фон, размер, позиции иконок
osascript <<AS
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 12
    set background picture of opts to file ".background:bg.tiff"
    set position of item "$APP_NAME.app" of container window to {170, 210}
    set position of item "Программы" of container window to {490, 210}
    set position of item "Как установить.txt" of container window to {590, 300}
    -- скрытые служебные элементы уводим за пределы окна: у части людей включён показ скрытых файлов
    repeat with n in {".background", ".fseventsd", ".Trashes", ".DS_Store", ".VolumeIcon.icns"}
      try
        set position of item (n as string) of container window to {1200, 900}
      end try
    end repeat
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
AS
sync
hdiutil detach "$VOL" -quiet
sleep 1

# 3) сжатый образ только для чтения
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$STAGE" "$RW"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
