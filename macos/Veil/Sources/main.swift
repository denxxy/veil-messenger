import Foundation

// Входная точка приложения. main.swift — единственный файл с top-level кодом:
// режим `--selftest` выполняет самопроверку (используется в build.sh) без GUI.

enum AppSelfTest {
    static func run() -> Bool {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ok   \(name)") }
            else { failed += 1; print("  FAIL \(name)") }
        }

        let a = VeilIdentity.generate()
        let b = VeilIdentity.generate()
        check("identity: ключи 64 hex", a.signPubHex.count == 64 && a.xPubHex.count == 64)

        // invite roundtrip
        let invite = InvitePayload(v: 1, n: "Тест", s: b.signPubHex, x: b.xPubHex,
                                   r: ["https://relay.example.com"])
        check("invite: кодирование/разбор", Invite.parse(Invite.encode(invite)) == invite)
        check("invite: мусор отклоняется", Invite.parse("не-invite!!") == nil)

        // ключи направлений: A→B и B→A
        guard let ka = try? VeilCrypto.directionKeys(myXPriv: a.agreement,
                                                     theirXPubHex: b.xPubHex,
                                                     mySignPubHex: a.signPubHex,
                                                     theirSignPubHex: b.signPubHex),
              let kb = try? VeilCrypto.directionKeys(myXPriv: b.agreement,
                                                     theirXPubHex: a.xPubHex,
                                                     mySignPubHex: b.signPubHex,
                                                     theirSignPubHex: a.signPubHex)
        else {
            print("  FAIL directionKeys threw")
            return false
        }

        let plaintext = Data("Привет, Боб! Тест Veil 🎉".utf8)
        if let sealed = try? VeilCrypto.seal(plaintext, key: ka.send),
           let opened = try? VeilCrypto.open(sealed, key: kb.receive) {
            check("шифрование A→B", opened == plaintext)
            // подделка байта должна ломать тег
            var tampered = sealed
            tampered[tampered.count - 1] ^= 0xFF
            check("подмена отклоняется", (try? VeilCrypto.open(tampered, key: kb.receive)) == nil)
            // обратное направление
            if let sealed2 = try? VeilCrypto.seal(plaintext, key: kb.send),
               let opened2 = try? VeilCrypto.open(sealed2, key: ka.receive) {
                check("шифрование B→A", opened2 == plaintext)
            } else {
                check("шифрование B→A", false)
            }
        } else {
            check("шифрование A→B", false)
        }

        // самопереписка: оба направления одним ключом
        if let ks = try? VeilCrypto.directionKeys(myXPriv: a.agreement,
                                                  theirXPubHex: a.xPubHex,
                                                  mySignPubHex: a.signPubHex,
                                                  theirSignPubHex: a.signPubHex) {
            let sealed = try? VeilCrypto.seal(plaintext, key: ks.send)
            let opened = sealed.flatMap { try? VeilCrypto.open($0, key: ks.receive) }
            check("Избранное: шифрование самому себе", opened == plaintext)
        } else {
            check("Избранное: шифрование самому себе", false)
        }

        // транспортная подпись
        let sig64 = VeilCrypto.authSignature(purpose: "inbox", user: a.signPubHex,
                                             ts: 1234567890, nonce: "abcd1234",
                                             signingKey: a.signing)
        if let sig = Data(base64Encoded: sig64) {
            let msg = Data("inbox:\(a.signPubHex):1234567890:abcd1234".utf8)
            check("auth-подпись проверяется",
                  a.signing.publicKey.isValidSignature(sig, for: msg))
            check("auth-подпись ломается при изменении данных",
                  !a.signing.publicKey.isValidSignature(sig, for: Data("inbox:\(a.signPubHex):1234567891:abcd1234".utf8)))
            check("auth-подписи в одну секунду различаются (nonce)",
                  VeilCrypto.authSignature(purpose: "inbox", user: a.signPubHex,
                                           ts: 1234567890, nonce: "ffff0000",
                                           signingKey: a.signing) != sig64)
        } else {
            check("auth-подпись проверяется", false)
        }

        // подпись конверта + проверка получателем
        let payload = Data((0..<64).map { _ in UInt8.random(in: .min ... .max) })
        let esig64 = VeilCrypto.envelopeSignature(xPubHex: a.xPubHex, payload: payload,
                                                  signingKey: a.signing)
        if let esig = Data(base64Encoded: esig64) {
            check("подпись конверта проверяется",
                  VeilCrypto.verifyEnvelopeSignature(sig: esig, senderXPubHex: a.xPubHex,
                                                     senderSignPubHex: a.signPubHex,
                                                     payload: payload))
            check("подпись конверта с чужим ключом отклоняется",
                  !VeilCrypto.verifyEnvelopeSignature(sig: esig, senderXPubHex: b.xPubHex,
                                                      senderSignPubHex: a.signPubHex,
                                                      payload: payload))
        } else {
            check("подпись конверта проверяется", false)
        }

        // экспорт/импорт identity
        let keys = a.keys
        check("identity: экспорт/импорт", VeilIdentity.from(keys: keys)?.signPubHex == a.signPubHex)
        let broken = IdentityKeys(signPriv: keys.signPriv, signPub: b.signPubHex,
                                  xPriv: keys.xPriv, xPub: keys.xPub, createdAt: 0)
        check("identity: несовпадение ключей отклоняется", VeilIdentity.from(keys: broken) == nil)

        print("selftest: \(passed) passed, \(failed) failed")
        return failed == 0
    }
}

if CommandLine.arguments.contains("--selftest") {
    let ok = AppSelfTest.run()
    exit(ok ? 0 : 1)
}

VeilApp.main()
