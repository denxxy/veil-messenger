#!/bin/bash
# Межъязыковой тест криптографии: python (Алиса) -> Swift (Боб) -> python.
# Доказывает, что выведение ключей, шифрование и подписи полностью совпадают
# между CryptoKit (macOS-клиент) и cryptography (эталон).
#
# Запуск из корня репозитория: bash tests/interop/run.sh

set -euo pipefail
cd "$(dirname "$0")/../.."

PY="${PY:-.venv/bin/python}"

echo "== 1/4 Генерация вектора (python, Алиса)"
"$PY" tests/interop/gen_vector.py

echo "== 2/4 Компиляция Swift-теста (Боб)"
mkdir -p build/interop
cat > build/interop/main.swift <<'EOF'
import Foundation
let ok = SwiftInteropTest.run()
exit(ok ? 0 : 1)
EOF
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
    macos/Veil/Sources/Crypto.swift \
    tests/interop/SwiftTestMain.swift \
    build/interop/main.swift \
    -o build/interop/veil_interop

echo "== 3/4 Проверка конверта и ответ (Swift, Боб)"
./build/interop/veil_interop tests/interop/vector.json tests/interop/reply.json

echo "== 4/4 Проверка ответа Боба (python, Алиса)"
"$PY" tests/interop/verify_reply.py

echo
echo "Интероп-тест пройден: Swift и Python совместимы на уровне протокола."
