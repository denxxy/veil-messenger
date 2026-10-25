#!/bin/bash
# Кросс-проверка iOS-приложения без Xcode: UI (ViewsIOS.swift) написан на
# кросс-платформенном SwiftUI, поэтому компилируется и запускается на macOS.
# Ошибка компиляции здесь = ошибка сборки iOS. Полная сборка iOS — в Xcode
# (см. ios/README.md).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Компиляция ядра + iOS-UI для macOS (эквивалент iOS-сборки)"
rm -rf build/ioscheck
mkdir -p build/ioscheck
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
    macos/Veil/Sources/Crypto.swift \
    macos/Veil/Sources/Models.swift \
    macos/Veil/Sources/Store.swift \
    macos/Veil/Sources/RelayService.swift \
    ios/VeilIOS/ViewsIOS.swift \
    ios/check/main.swift \
    -o build/ioscheck/veil_ios_check

echo "==> Запуск UI в окне (6 сек, авто-выход = успех)"
VEIL_HOME="$(mktemp -d)/veil-home" ./build/ioscheck/veil_ios_check

echo
echo "Проверка пройдена: iOS-UI компилируется и работает."
