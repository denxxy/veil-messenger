#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Сквозной тест: два клиента (Алиса, Боб) обмениваются сообщением через
настоящую relay-ноду — с E2E-шифрованием, подписями конвертов и
Ed25519-аутентификацией fetch. Всё по тому же протоколу, что использует
macOS-клиент.

Запуск из корня репозитория:
    .venv/bin/python tests/e2e_two_clients.py
"""

import asyncio
import base64
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

import aiohttp
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.serialization import (
    Encoding, NoEncryption, PrivateFormat, PublicFormat,
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8994
BASE = "http://127.0.0.1:%d" % PORT

passed, failed = 0, 0


def check(name, cond, extra=""):
    global passed, failed
    if cond:
        passed += 1
        print("  ok   %s" % name)
    else:
        failed += 1
        print("  FAIL %s %s" % (name, extra))


def pub_hex(key):
    return key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()


def priv_hex(key):
    return key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption()).hex()


def hkdf_sha256(ikm, salt, info, length):
    import hashlib
    import hmac
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    okm, t, i = b"", b"", 1
    while len(okm) < length:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        okm += t
        i += 1
    return okm[:length]


class Client:
    """Минимальный клиент протокола Veil v1 (python-эквивалент Swift-кода)."""

    def __init__(self, name):
        self.name = name
        self.sign = Ed25519PrivateKey.generate()
        self.x = X25519PrivateKey.generate()
        self.sign_pub = pub_hex(self.sign)
        self.x_pub = pub_hex(self.x)
        self.relays = [BASE]

    def conversation_keys(self, peer_x_pub, peer_sign_pub):
        shared = self.x.exchange(
            X25519PublicKey.from_public_bytes(bytes.fromhex(peer_x_pub)))
        lo, hi = sorted([self.sign_pub, peer_sign_pub])
        info = ("VEIL-CTX-V1:%s:%s" % (lo, hi)).encode()
        okm = hkdf_sha256(shared, b"VEIL-SALT-V1", info, 64)
        send, recv = okm[:32], okm[32:]
        return (send, recv) if self.sign_pub == lo else (recv, send)

    def encrypt_to(self, text, msg_id, peer):
        send, _ = self.conversation_keys(peer.x_pub, peer.sign_pub)
        inner = {"i": msg_id, "t": text,
                 "ts": int(time.time() * 1000), "r": self.relays}
        pt = json.dumps(inner, ensure_ascii=False, separators=(",", ":")).encode()
        nonce = os.urandom(12)
        payload = nonce + ChaCha20Poly1305(send).encrypt(nonce, pt, None)
        sig = self.sign.sign(bytes.fromhex(self.x_pub) + payload)
        return {"to": peer.sign_pub, "from": self.sign_pub, "from_x": self.x_pub,
                "payload": base64.b64encode(payload).decode(),
                "sig": base64.b64encode(sig).decode()}

    def decrypt_from(self, env, peer):
        _, recv = self.conversation_keys(env["sender_x"], env["sender"])
        payload = base64.b64decode(env["payload"])
        pt = ChaCha20Poly1305(recv).decrypt(payload[:12], payload[12:], None)
        return json.loads(pt.decode("utf-8"))

    def inbox_headers(self):
        ts = int(time.time())
        nonce = os.urandom(8).hex()
        msg = ("inbox:%s:%d:%s" % (self.sign_pub, ts, nonce)).encode()
        return {"X-Veil-User": self.sign_pub, "X-Veil-Timestamp": str(ts),
                "X-Veil-Nonce": nonce,
                "X-Veil-Signature": base64.b64encode(self.sign.sign(msg)).decode()}


async def main():
    dbpath = os.path.join(tempfile.mkdtemp(prefix="veil-e2e-"), "db.sqlite")
    server = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "relay", "veil_relay.py"),
         "--host", "127.0.0.1", "--port", str(PORT), "--db", dbpath,
         "--rate-per-minute", "10000"],
        stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    try:
        alice = Client("Алиса")
        bob = Client("Боб")
        text = "Проверка сквозного шифрования через relay! 🚀"

        async with aiohttp.ClientSession() as s:
            for _ in range(60):
                try:
                    async with s.get(BASE + "/health") as r:
                        if r.status == 200:
                            break
                except Exception:
                    pass
                await asyncio.sleep(0.5)

            print("== Алиса -> relay -> Боб (REST)")
            env = alice.encrypt_to(text, "e2e-1", bob)
            async with s.post(BASE + "/api/v1/envelopes", json=env) as r:
                check("конверт принят relay", r.status == 202, "got %s" % r.status)

            async with s.get(BASE + "/api/v1/inbox",
                             headers=bob.inbox_headers()) as r:
                body = await r.json()
                envs = body.get("envelopes", [])
                check("Боб получил конверт из своего inbox", len(envs) == 1)
                got = envs[0]
                check("relay не подменил отправителя",
                      got["sender"] == alice.sign_pub
                      and got["sender_x"] == alice.x_pub)
                inner = bob.decrypt_from(got, alice)
                check("расшифровка у Боба совпала", inner["t"] == text)
                check("relay-адреса Алисы доставлены", inner["r"] == [BASE])

            print("== Боб -> relay -> Алиса (ответ)")
            reply_env = bob.encrypt_to("Принято!", "e2e-2", alice)
            async with s.post(BASE + "/api/v1/envelopes", json=reply_env) as r:
                check("ответ принят relay", r.status == 202)
            async with s.get(BASE + "/api/v1/inbox",
                             headers=alice.inbox_headers()) as r:
                envs = (await r.json()).get("envelopes", [])
                check("Алиса получила ответ", len(envs) == 1)
                inner = alice.decrypt_from(envs[0], bob)
                check("расшифровка ответа у Алисы", inner["t"] == "Принято!")

            print("== изоляция почтовых ящиков")
            eve = Client("Ева")
            async with s.get(BASE + "/api/v1/inbox",
                             headers=eve.inbox_headers()) as r:
                envs = (await r.json()).get("envelopes", [])
                check("чужой ящик пуст для Евы", envs == [])
            # Ева не может притвориться Бобом даже с валидной своей подписью:
            # подпись alice.sign не примется для user=bob
            ts = int(time.time())
            forged = {"X-Veil-User": bob.sign_pub, "X-Veil-Timestamp": str(ts),
                      "X-Veil-Nonce": os.urandom(8).hex()}
            forged["X-Veil-Signature"] = base64.b64encode(
                eve.sign.sign(("inbox:%s:%d:%s" % (bob.sign_pub, ts,
                                                   forged["X-Veil-Nonce"])).encode())).decode()
            async with s.get(BASE + "/api/v1/inbox", headers=forged) as r:
                check("подпись Евы за Боба отклонена (401)", r.status == 401)

            # подмена шифротекеста ломает расшифровку Боба
            print("== целостность")
            tampered = dict(env)
            raw = bytearray(base64.b64decode(tampered["payload"]))
            raw[-1] ^= 0xFF
            tampered["payload"] = base64.b64encode(bytes(raw)).decode()
            try:
                bob.decrypt_from(tampered, alice)
                check("подмена байта отклонена AEAD", False)
            except Exception:
                check("подмена байта отклонена AEAD", True)
    finally:
        server.send_signal(signal.SIGTERM)
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()

    print("\ne2e: %d passed, %d failed" % (passed, failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    asyncio.run(main())
