#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Сквозной тест Windows-клиента (windows/veil_core.py) через живой relay:

 1. прямой обмен: Алиса -> relay -> Боб (REST, тот же код, что в GUI-клиенте)
 2. живые фоновые потоки: Боб слушает polling, Алиса отправляет send_message
 3. WebSocket-push: Боб подключён по WS, Алиса шлёт через REST
 4. совместимость с macOS-клиентом: конверт, собранный Swift-кодом
    (тест-вектор из tests/interop), расшифровывается ядром python-клиента
 5. файл личности: формат общий с экспортом macOS-приложения

Запуск из корня репозитория:
    .venv/bin/python tests/windows_client_e2e.py
"""

import base64
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "windows"))

import veil_core as core  # noqa: E402

PORT = 8995
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


def make_core(name):
    state = core.ClientState(os.path.join(
        tempfile.mkdtemp(prefix="veil-win-"), "store.json"))
    identity = core.VeilIdentity.generate()
    state.set_identity(identity, name)
    state.add_relay(BASE)
    return core.VeilClientCore(state), state


def wait_relay():
    for _ in range(60):
        if core.RelayTransport.health(BASE):
            return True
        time.sleep(0.5)
    return False


def main():
    server = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "relay", "veil_relay.py"),
         "--host", "127.0.0.1", "--port", str(PORT),
         "--db", os.path.join(tempfile.mkdtemp(prefix="veil-win-db-"), "db.sqlite"),
         "--rate-per-minute", "10000"],
        stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    try:
        check("relay поднялся", wait_relay())
        alice_core, alice_state = make_core("Алиса")
        bob_core, bob_state = make_core("Боб")
        alice = alice_state.identity
        bob = bob_state.identity

        # приглашение как между разными платформами
        invite = core.parse_invite(core.encode_invite(
            "Алиса (Windows)", alice.sign_pub_hex, alice.x_pub_hex, [BASE]))
        check("invite: Боб добавил Алису", bob_state.add_contact_from_invite(invite))
        check("invite: контакт с ключами и реле",
              bob_state.contact(alice.sign_pub_hex)["xPub"] == alice.x_pub_hex)

        print("== 1. Прямой обмен REST (код клиента, без потоков)")
        env = alice_core.build_envelope(alice, "Привет от Windows! 🪟", "w1",
                                        bob.sign_pub_hex, bob.x_pub_hex)
        check("конверт доставлен на relay",
              core.RelayTransport.post_envelope(BASE, env))
        fetched = core.RelayTransport.fetch_inbox(BASE, bob)
        check("inbox отдаёт конверт", fetched and len(fetched) == 1)
        event = bob_core.handle_envelope(fetched[0])
        msgs = [m for m in bob_state.data["messages"]
                if m["contactId"] == alice.sign_pub_hex]
        check("сообщение расшифровано и сохранено",
              event == "message" and msgs and msgs[0]["text"] == "Привет от Windows! 🪟")
        check("авто-контект у Боба не дублируется",
              len([c for c in bob_state.data["contacts"]
                   if c["signPub"] == alice.sign_pub_hex]) == 1)

        print("== 2. Живые потоки: polling-петля Боба")
        # Алисе нужен контакт Боба, чтобы знать его X25519-ключ
        check("контакт Боба у Алисы",
              alice_state.add_contact_from_invite(core.parse_invite(
                  core.encode_invite("Боб", bob.sign_pub_hex, bob.x_pub_hex, [BASE]))))
        got_event = []
        bob_core.on_event = lambda kind, payload: got_event.append((kind, payload))
        bob_core.start()
        sent = alice_core.send_message("Потоковая проверка", bob.sign_pub_hex)
        check("send_message вернул доставку", sent)
        deadline = time.time() + 20
        while time.time() < deadline:
            if any(m["text"] == "Потоковая проверка" and m["incoming"]
                   for m in bob_state.data["messages"]):
                break
            time.sleep(0.3)
        check("Боб получил через polling-поток",
              any(m["text"] == "Потоковая проверка" and m["incoming"]
                  for m in bob_state.data["messages"]))
        check("статус доставки у Алисы отмечен",
              any(m["text"] == "Потоковая проверка" and m.get("delivered")
                  for m in alice_state.data["messages"]))
        bob_core.stop()

        print("== 3. WebSocket-push")
        import queue as qmod
        ws_events = qmod.Queue()
        bob_core2, bob_state2 = make_core("Боб2")
        # та же личность Боба, новый core — чистый WS-путь
        bob_state2.data["identity"] = bob_state.data["identity"]
        bob_state2.save()
        bob_core2.on_event = lambda kind, payload: ws_events.put(kind)
        bob_core2.start()
        time.sleep(2)  # WS успел подключиться и авторизоваться
        check("WS-потоки подняты", bool(bob_core2._ws_threads))
        env2 = alice_core.build_envelope(alice, "push по WS", "w2",
                                         bob.sign_pub_hex, bob.x_pub_hex)
        check("конверт для WS-получателя отправлен",
              core.RelayTransport.post_envelope(BASE, env2))
        got_ws = False
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                if ws_events.get(timeout=0.3) == "message":
                    got_ws = True
                    break
            except Exception:
                pass
        check("push доставлен по WebSocket и расшифрован", got_ws)
        bob_core2.stop()

        print("== 4. Конверт, собранный Swift (macOS-клиентом)")
        vector_path = os.path.join(ROOT, "tests", "interop", "vector.json")
        if not os.path.exists(vector_path):
            subprocess.check_call([sys.executable,
                                   os.path.join(ROOT, "tests", "interop",
                                                "gen_vector.py")],
                                  stdout=subprocess.DEVNULL)
        with open(vector_path, encoding="utf-8") as f:
            vector = json.load(f)
        # пересоберём envelope Алисы из вектора и скормим ядру python-клиента
        swift_env = {
            "id": "1",
            "sender": vector["alice"]["sign_pub"],
            "sender_x": vector["alice"]["x_pub"],
            "payload": vector["envelope"]["payload"],
            "sig": vector["envelope"]["sig"],
            "created": time.time(),
        }
        carol_state = core.ClientState(os.path.join(
            tempfile.mkdtemp(prefix="veil-win-c"), "store.json"))
        # вектор интероп-теста использует snake_case; файл личности — camelCase
        vb = vector["bob"]
        carol_keys = {"signPriv": vb["sign_priv"], "signPub": vb["sign_pub"],
                      "xPriv": vb["x_priv"], "xPub": vb["x_pub"], "createdAt": 0}
        carol_identity = core.VeilIdentity.from_keys_dict(carol_keys)
        carol_state.set_identity(carol_identity, "Кэрол")
        carol_core = core.VeilClientCore(carol_state)
        event = carol_core.handle_envelope(swift_env)
        msgs = [m for m in carol_state.data["messages"]]
        check("swift-конверт расшифрован python-ядром",
              event == "message" and msgs
              and msgs[0]["text"] == vector["message"])
        check("авто-контракт из swift-конверта получил relay-адреса",
              msgs and carol_state.contact(vector["alice"]["sign_pub"])["relays"]
              == ["https://relay1.example.com", "https://relay2.example.com"])

        print("== 5. Формат файла личности (общий с macOS)")
        d = alice.to_keys_dict()
        check("camelCase-поля как в IdentityKeys Swift",
              set(d) == {"signPriv", "signPub", "xPriv", "xPub", "createdAt"})
        check("roundtrip через файл",
              core.VeilIdentity.from_keys_dict(
                  json.loads(json.dumps(d))).sign_pub_hex == alice.sign_pub_hex)

        # Избранное: отправка самому себе через свой relay
        print("== 6. Избранное")
        me_core, me_state = make_core("Я")
        ok = me_core.send_message("заметка себе", me_state.identity.sign_pub_hex)
        check("заметка доставлена себе", ok)
        fetched = core.RelayTransport.fetch_inbox(BASE, me_state.identity)
        event = me_core.handle_envelope(fetched[0])
        mine = me_state.data["messages"]
        check("заметка вернулась и помечена доставленной",
              event == "delivery" and len(mine) == 1 and mine[0]["delivered"])
    finally:
        server.send_signal(signal.SIGTERM)
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()

    print("\nwindows client e2e: %d passed, %d failed" % (passed, failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
