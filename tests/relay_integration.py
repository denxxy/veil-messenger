#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Интеграционный тест relay-ноды: поднимает veil_relay.py и прогоняет
REST/WebSocket сценарии с настоящими Ed25519-подписями.

Запуск из корня репозитория:
    .venv/bin/python tests/relay_integration.py
"""

import asyncio
import base64
import os
import signal
import subprocess
import sys
import tempfile
import time

import aiohttp
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8991
BASE = "http://127.0.0.1:%d" % PORT

passed, failed = 0, 0


def pub_hex(key):
    return key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()


def check(name, cond, extra=""):
    global passed, failed
    if cond:
        passed += 1
        print("  ok   %s" % name)
    else:
        failed += 1
        print("  FAIL %s %s" % (name, extra))


def sign_headers(priv, user_hex, purpose):
    ts = int(time.time())
    nonce = os.urandom(8).hex()
    msg = ("%s:%s:%d:%s" % (purpose, user_hex, ts, nonce)).encode()
    return {
        "X-Veil-User": user_hex,
        "X-Veil-Timestamp": str(ts),
        "X-Veil-Nonce": nonce,
        "X-Veil-Signature": base64.b64encode(priv.sign(msg)).decode(),
    }


def ws_auth_frame(priv, user_hex):
    ts = int(time.time())
    nonce = os.urandom(8).hex()
    msg = ("ws:%s:%d:%s" % (user_hex, ts, nonce)).encode()
    return {"type": "auth", "user": user_hex, "ts": ts, "nonce": nonce,
            "signature": base64.b64encode(priv.sign(msg)).decode()}


async def wait_health(session):
    for _ in range(60):
        try:
            async with session.get(BASE + "/health",
                                   timeout=aiohttp.ClientTimeout(total=1)) as r:
                if r.status == 200:
                    return True
        except Exception:
            pass
        await asyncio.sleep(0.5)
    return False


async def main():
    dbpath = os.path.join(tempfile.mkdtemp(prefix="veil-test-"), "test.db")
    server = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "relay", "veil_relay.py"),
         "--host", "127.0.0.1", "--port", str(PORT), "--db", dbpath,
         "--rate-per-minute", "10000"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        alice = Ed25519PrivateKey.generate()
        bob = Ed25519PrivateKey.generate()
        alice_hex, bob_hex = pub_hex(alice), pub_hex(bob)
        payload = base64.b64encode(os.urandom(48)).decode()
        sig = base64.b64encode(alice.sign(b"whatever")).decode()

        async with aiohttp.ClientSession() as s:
            print("== запуск, health и decoy-страница")
            check("health отвечает", await wait_health(s))
            async with s.get(BASE + "/") as r:
                page = (await r.text()).lower()
                check("decoy-страница отдаётся и не выдаёт Veil",
                      r.status == 200 and "<html" in page and "veil" not in page)

            print("== POST /api/v1/envelopes")
            async with s.post(BASE + "/api/v1/envelopes", json={
                    "to": bob_hex, "from": alice_hex, "from_x": alice_hex,
                    "payload": payload, "sig": sig}) as r:
                check("валидный конверт принят (202)", r.status == 202,
                      "got %s" % r.status)
            async with s.post(BASE + "/api/v1/envelopes", json={
                    "to": "xyz", "from": alice_hex, "from_x": alice_hex,
                    "payload": payload, "sig": sig}) as r:
                check("невалидный ключ отклонён (400)", r.status == 400)
            async with s.post(BASE + "/api/v1/envelopes", json={}) as r:
                check("пустое тело отклонено (400)", r.status == 400)
            async with s.post(BASE + "/api/v1/envelopes", json={
                    "to": bob_hex, "from": alice_hex, "from_x": alice_hex,
                    "payload": "A" * 200000, "sig": sig}) as r:
                check("огромный payload отклонён", r.status in (400, 413))

            print("== GET /api/v1/inbox")
            async with s.get(BASE + "/api/v1/inbox") as r:
                check("без подписи отклонено (401)", r.status == 401)
            async with s.get(BASE + "/api/v1/inbox", headers={
                    "X-Veil-User": bob_hex,
                    "X-Veil-Timestamp": str(int(time.time())),
                    "X-Veil-Signature": base64.b64encode(os.urandom(64)).decode()}) as r:
                check("плохая подпись отклонена (401)", r.status == 401)
            stale_ts = int(time.time()) - 1000
            stale_nonce = os.urandom(8).hex()
            async with s.get(BASE + "/api/v1/inbox", headers={
                    "X-Veil-User": bob_hex,
                    "X-Veil-Timestamp": str(stale_ts),
                    "X-Veil-Nonce": stale_nonce,
                    "X-Veil-Signature": base64.b64encode(
                        bob.sign(("inbox:%s:%d:%s" % (bob_hex, stale_ts, stale_nonce)).encode())).decode()
                    }) as r:
                check("просроченный timestamp отклонён (401)", r.status == 401)

            hdrs = sign_headers(bob, bob_hex, "inbox")
            async with s.get(BASE + "/api/v1/inbox", headers=hdrs) as r:
                body = await r.json()
                check("авторизованный запрос прошёл", r.status == 200)
                envs = body.get("envelopes", [])
                check("конверт получен", len(envs) == 1 and envs[0]["payload"] == payload)
                check("метаданные конверта на месте",
                      envs[0]["sender"] == alice_hex
                      and envs[0]["sender_x"] == alice_hex
                      and "created" in envs[0] and "id" in envs[0])
            async with s.get(BASE + "/api/v1/inbox", headers=hdrs) as r:
                body = await r.json()
                check("повторный fetch тем же кодом — 401 (replay)",
                      r.status == 401)
            async with s.get(BASE + "/api/v1/inbox",
                             headers=sign_headers(bob, bob_hex, "inbox")) as r:
                body = await r.json()
                check("новая подпись принята, inbox пуст (fetch-and-delete)",
                      r.status == 200 and body.get("envelopes") == [])

            print("== WebSocket")
            async with s.ws_connect(BASE + "/api/v1/ws") as ws:
                await ws.send_json({"type": "auth", "user": bob_hex,
                                    "ts": int(time.time()), "nonce": os.urandom(8).hex(),
                                    "signature": base64.b64encode(os.urandom(64)).decode()})
                msg = await asyncio.wait_for(ws.receive_json(), timeout=5)
                check("WS: неверный auth -> error", msg.get("type") == "error")
            async with s.ws_connect(BASE + "/api/v1/ws") as ws:
                await ws.send_json(ws_auth_frame(bob, bob_hex))
                msg = await asyncio.wait_for(ws.receive_json(), timeout=5)
                check("WS: auth принят -> ready", msg.get("type") == "ready")
                async with s.post(BASE + "/api/v1/envelopes", json={
                        "to": bob_hex, "from": alice_hex, "from_x": alice_hex,
                        "payload": payload, "sig": sig}) as r:
                    check("WS: конверт для онлайн-получателя отправлен", r.status == 202)
                msg = await asyncio.wait_for(ws.receive_json(), timeout=5)
                check("WS: push доставлен",
                      msg.get("type") == "envelope"
                      and msg["envelope"]["payload"] == payload)
            async with s.get(BASE + "/api/v1/inbox",
                             headers=sign_headers(bob, bob_hex, "inbox")) as r:
                body = await r.json()
                check("после WS push poll тоже отдаёт (дедуп на клиенте)",
                      r.status == 200 and len(body.get("envelopes", [])) >= 1)
    finally:
        server.send_signal(signal.SIGTERM)
        try:
            out = server.communicate(timeout=5)[0]
        except subprocess.TimeoutExpired:
            server.kill()
            out = server.communicate()[0]
        if failed:
            print("--- вывод сервера ---")
            print(out.decode("utf-8", "replace")[-3000:])

    print("\nrelay integration: %d passed, %d failed" % (passed, failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    asyncio.run(main())
