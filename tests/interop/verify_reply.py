#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Проверка ответа Боба (Swift) стороной Алисы (python): расшифровка,
проверка подписи и текста. Завершает межъязыковой тест криптографии."""

import base64
import hashlib
import hmac
import json
import os

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

HERE = os.path.dirname(os.path.abspath(__file__))


def hkdf_sha256(ikm, salt, info, length):
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    okm, t, i = b"", b"", 1
    while len(okm) < length:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        okm += t
        i += 1
    return okm[:length]


def main():
    with open(os.path.join(HERE, "vector.json"), encoding="utf-8") as f:
        vector = json.load(f)
    with open(os.path.join(HERE, "reply.json"), encoding="utf-8") as f:
        reply = json.load(f)

    # приватные ключи Алисы вектор не сохранил (не нужны были Swift-у),
    # поэтому общий секрет считаем от обратного: ключи направления
    # восстанавливаем через ключи Боба из reply + публичные Алисы.
    # Но для расшифровки Алисе нужен ЕЁ приватный X25519 — потому кладём его
    # в vector.json (см. gen_vector: "alice_priv_x").
    alice_x_priv = bytes.fromhex(vector["alice_priv_x"])
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    alice_x = X25519PrivateKey.from_private_bytes(alice_x_priv)

    a_sign_pub = vector["alice"]["sign_pub"]
    b_sign_pub = reply["bob_sign_pub"]
    b_x_pub = reply["bob_x_pub"]

    shared = alice_x.exchange(X25519PublicKey.from_public_bytes(bytes.fromhex(b_x_pub)))
    lo, hi = sorted([a_sign_pub, b_sign_pub])
    info = ("VEIL-CTX-V1:%s:%s" % (lo, hi)).encode()
    okm = hkdf_sha256(shared, b"VEIL-SALT-V1", info, 64)
    alice_recv = okm[32:] if a_sign_pub == lo else okm[:32]

    payload = base64.b64decode(reply["payload"])
    sig = base64.b64decode(reply["sig"])

    # 1. подпись Боба
    try:
        Ed25519PublicKey.from_public_bytes(bytes.fromhex(b_sign_pub)).verify(
            sig, bytes.fromhex(b_x_pub) + payload)
        print("  ok   подпись Боба проверена")
    except InvalidSignature:
        print("FAIL: подпись Боба не прошла")
        raise SystemExit(1)

    # 2. расшифровка
    plaintext = ChaCha20Poly1305(alice_recv).decrypt(payload[:12], payload[12:], None)
    inner = json.loads(plaintext.decode("utf-8"))
    if inner["t"] != reply["reply_text"] or inner["i"] != "swift-1":
        print("FAIL: расшифрованный ответ не совпал")
        raise SystemExit(1)
    print("  ok   ответ расшифрован: %s" % inner["t"])
    print("  ok   ключи Swift и Python выведены одинаково — протокол совместим")
    print("PYTHON-OK")


if __name__ == "__main__":
    main()
