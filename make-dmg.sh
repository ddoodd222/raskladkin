#!/bin/zsh
# Собирает dist/Раскладкин.dmg для раздачи. Запуск: ./make-dmg.sh (сначала ./build.sh)
set -e
cd "$(dirname "$0")"
APP_NAME="Раскладкин"
APP="dist/$APP_NAME.app"
[ -d "$APP" ] || { echo "Сначала ./build.sh"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE="dist/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Программы"
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
• ⌘⇧A — чинит выделенный текст, а без выделения — последнее слово.
• Автомат: после трёх подряд слов не в той раскладке сам всё перепечатает.
• Настройки, порог, хоткей и выключение — в меню по клику на иконку.
TXT
DMG="dist/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
