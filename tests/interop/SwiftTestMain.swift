import CryptoKit
import Foundation

/// Сторона Боба (Swift): проверяет конверт Алисы из vector.json, расшифровывает
/// его теми же примитивами, что и приложение (VeilCrypto), и отвечает Алисе —
/// ответ кладёт в reply.json, который python затем расшифровывает и проверяет.
enum SwiftInteropTest {
    struct Inner: Codable {
        let i: String
        let t: String
        let ts: Double
        let r: [String]
    }

    static func run() -> Bool {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: veil_interop vector.json reply.json")
            return false
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
            guard let vec = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let alice = vec["alice"] as? [String: Any],
                  let bob = vec["bob"] as? [String: Any],
                  let envelope = vec["envelope"] as? [String: Any],
                  let expected = vec["message"] as? String
            else {
                print("FAIL: битый vector.json")
                return false
            }

            // личные ключи Боба из вектора -> identity
            guard let signPriv = Data(hexString: bob["sign_priv"] as? String ?? ""),
                  let xPriv = Data(hexString: bob["x_priv"] as? String ?? ""),
                  let bobSign = try? Curve25519.Signing.PrivateKey(rawRepresentation: signPriv),
                  let bobX = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: xPriv)
            else {
                print("FAIL: не читаются приватные ключи Боба")
                return false
            }
            let bSignPub = bobSign.publicKey.rawRepresentation.hexString
            let bXPub = bobX.publicKey.rawRepresentation.hexString
            guard bSignPub == (bob["sign_pub"] as? String ?? ""),
                  bXPub == (bob["x_pub"] as? String ?? "")
            else {
                print("FAIL: публичные ключи вектора не сходятся с приватными")
                return false
            }

            let aSignPub = alice["sign_pub"] as? String ?? ""
            let aXPub = alice["x_pub"] as? String ?? ""
            let payload = Data(base64Encoded: envelope["payload"] as? String ?? "") ?? Data()
            let sig = Data(base64Encoded: envelope["sig"] as? String ?? "") ?? Data()

            // 1. подпись Алисы поверх raw(x_pub) || ciphertext
            guard VeilCrypto.verifyEnvelopeSignature(sig: sig, senderXPubHex: aXPub,
                                                     senderSignPubHex: aSignPub,
                                                     payload: payload) else {
                print("FAIL: подпись конверта не прошла проверку")
                return false
            }
            print("  ok   подпись Алисы проверена")

            // 2. ключи направления + расшифровка
            let keys = try VeilCrypto.directionKeys(myXPriv: bobX, theirXPubHex: aXPub,
                                                    mySignPubHex: bSignPub,
                                                    theirSignPubHex: aSignPub)
            let plaintext = try VeilCrypto.open(payload, key: keys.receive)
            let inner = try JSONDecoder().decode(Inner.self, from: plaintext)
            guard inner.t == expected else {
                print("FAIL: текст не совпал: \(inner.t)")
                return false
            }
            print("  ok   сообщение расшифровано: \(inner.t)")
            print("  ok   relay-адреса Алисы: \(inner.r)")

            // 3. ответ Боба
            let replyText = (vec["reply_expect"] as? String ?? "")
            let reply = Inner(i: "swift-1", t: replyText, ts: 1770000001000,
                              r: ["https://relay.example.com"])
            let replyData = try JSONEncoder().encode(reply)
            let sealed = try VeilCrypto.seal(replyData, key: keys.send)
            let replySig = VeilCrypto.envelopeSignature(xPubHex: bXPub, payload: sealed,
                                                        signingKey: bobSign)

            let out: [String: Any] = [
                "payload": sealed.base64EncodedString(),
                "sig": replySig,
                "bob_x_pub": bXPub,
                "bob_sign_pub": bSignPub,
                "reply_text": replyText,
            ]
            let outData = try JSONSerialization.data(withJSONObject: out,
                                                     options: [.prettyPrinted])
            try outData.write(to: URL(fileURLWithPath: args[2]))
            print("SWIFT-OK")
            return true
        } catch {
            print("FAIL: \(error)")
            return false
        }
    }
}
