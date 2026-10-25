#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Генератор тест-вектора для проверки совместимости криптографии
Swift (CryptoKit) и Python (cryptography).

Алиса (python) шифрует сообщение для Боба и складывает всё в vector.json:
ключи Боба (в т.ч. приватные), публичные ключи Алисы, конверт, ожидаемый текст.
"""

import base64
import hashlib
import hmac
import json
import os

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.serialization import (
    Encoding, NoEncryption, PrivateFormat, PublicFormat,
)

HERE = os.path.dirname(os.path.abspath(__file__))
MESSAGE = "Привет, Боб! Это межъязыковой тест Veil. 🎉"
REPLY_EXPECT = "Привет, Алиса! Ответ собран в Swift и расшифрован через Python. ✅"


def pub_hex(key):
    return key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()


def priv_hex(key):
    return key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption()).hex()


def hkdf_sha256(ikm, salt, info, length):
    """HKDF-SHA256 (RFC 5869) — должна совпадать с CryptoKit hkdfDerivedSymmetricKey."""
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    okm, t, i = b"", b"", 1
    while len(okm) < length:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        okm += t
        i += 1
    return okm[:length]


def main():
    alice_sign = Ed25519PrivateKey.generate()
    alice_x = X25519PrivateKey.generate()
    bob_sign = Ed25519PrivateKey.generate()
    bob_x = X25519PrivateKey.generate()

    a_sign_pub, a_x_pub = pub_hex(alice_sign), pub_hex(alice_x)
    b_sign_pub, b_x_pub = pub_hex(bob_sign), pub_hex(bob_x)

    # выведение ключей направления (в точности как в VeilCrypto.directionKeys)
    shared = alice_x.exchange(bob_x.public_key())
    lo, hi = sorted([a_sign_pub, b_sign_pub])
    info = ("VEIL-CTX-V1:%s:%s" % (lo, hi)).encode()
    okm = hkdf_sha256(shared, b"VEIL-SALT-V1", info, 64)
    key_lo, key_hi = okm[:32], okm[32:]
    alice_send = key_lo if a_sign_pub == lo else key_hi

    inner = {"i": "py-1", "t": MESSAGE, "ts": 1770000000000,
             "r": ["https://relay1.example.com", "https://relay2.example.com"]}
    plaintext = json.dumps(inner, ensure_ascii=False,
                           separators=(",", ":")).encode("utf-8")
    nonce = os.urandom(12)
    ciphertext = ChaCha20Poly1305(alice_send).encrypt(nonce, plaintext, None)
    payload = nonce + ciphertext
    sig = alice_sign.sign(bytes.fromhex(a_x_pub) + payload)

    vector = {
        "protocol": "veil-v1",
        "message": MESSAGE,
        "reply_expect": REPLY_EXPECT,
        "alice": {"sign_pub": a_sign_pub, "x_pub": a_x_pub},
        "alice_priv_x": priv_hex(alice_x),
        "bob": {"sign_pub": b_sign_pub, "x_pub": b_x_pub,
                "sign_priv": priv_hex(bob_sign), "x_priv": priv_hex(bob_x)},
        "envelope": {"payload": base64.b64encode(payload).decode(),
                     "sig": base64.b64encode(sig).decode()},
    }
    path = os.path.join(HERE, "vector.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(vector, f, ensure_ascii=False, indent=1)
    print("vector.json: Алиса -> Боба (публичные ключи Алисы + приватные Боба)")


if __name__ == "__main__":
    main()
