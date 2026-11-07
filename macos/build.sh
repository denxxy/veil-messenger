#!/bin/bash
# Сборка Veil.app без Xcode-проекта: swiftc + .app-обёртка + ad-hoc подпись.
#
#   bash macos/build.sh              — сборка (arm64 по умолчанию)
#   bash macos/build.sh --universal  — universal binary (arm64 + x86_64)
#
# Требования: Command Line Tools (swiftc) и macOS 13+.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=Veil
APP="$APP_NAME.app"
MIN_MACOS=13.0
ARCH_ARGS=()

if [[ "${1:-}" == "--universal" ]]; then
    ARCH_ARGS=(-arch arm64 -arch x86_64)
    echo "Сборка universal (arm64 + x86_64)…"
else
    ARCH_ARGS=(-target "$(uname -m)-apple-macos$MIN_MACOS")
    echo "Сборка arm64 (для Intel используйте --universal)…"
fi

echo "==> Компиляция Swift"
rm -rf build
mkdir -p build
swiftc -O -swift-version 5 \
    "${ARCH_ARGS[@]}" \
    -target "$(uname -m)-apple-macos$MIN_MACOS" \
    -o "build/$APP_NAME" \
    Veil/Sources/*.swift

echo "==> Самопроверка бинарника"
"./build/$APP_NAME" --selftest

echo "==> Сборка .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Veil/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
if [[ -f Veil/AppIcon.icns ]]; then
    cp Veil/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    echo "(!) AppIcon.icns не найден — приложение без иконки"
fi

if command -v codesign >/dev/null 2>&1; then
    # Убираем FinderInfo/файловые xattrs: иначе codesign падает на ad-hoc подписи
    # в бандле под iCloud/Documents ("resource fork ... not allowed").
    xattr -cr "$APP" >/dev/null 2>&1 || true
    codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
fi

echo
echo "Готово: $(pwd)/$APP"
echo "Запуск: open $(pwd)/$APP"
