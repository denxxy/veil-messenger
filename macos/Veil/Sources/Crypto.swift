import CryptoKit
import Foundation

// MARK: - Data helpers

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        guard hexString.allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var idx = hexString.startIndex
        while idx < hexString.endIndex {
            let next = hexString.index(after: idx)
            guard let b = UInt8(String(hexString[idx...next]), radix: 16) else { return nil }
            bytes.append(b)
            idx = hexString.index(idx, offsetBy: 2)
        }
        self = Data(bytes)
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var b64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }
}

// MARK: - Identity

/// Пара ключей пользователя: Ed25519 (идентичность, подписи) +
/// X25519 (шифрование, ECDH). Хранится только на устройстве.
struct IdentityKeys: Codable, Equatable {
    let signPriv: String   // hex
    let signPub: String    // hex (64)
    let xPriv: String      // hex
    let xPub: String       // hex (64)
    let createdAt: Double
}

struct VeilIdentity {
    let signing: Curve25519.Signing.PrivateKey
    let agreement: Curve25519.KeyAgreement.PrivateKey

    var signPubHex: String { signing.publicKey.rawRepresentation.hexString }
    var xPubHex: String { agreement.publicKey.rawRepresentation.hexString }

    static func generate() -> VeilIdentity {
        VeilIdentity(signing: Curve25519.Signing.PrivateKey(),
                     agreement: Curve25519.KeyAgreement.PrivateKey())
    }

    var keys: IdentityKeys {
        IdentityKeys(signPriv: signing.rawRepresentation.hexString,
                     signPub: signPubHex,
                     xPriv: agreement.rawRepresentation.hexString,
                     xPub: xPubHex,
                     createdAt: Date().timeIntervalSince1970)
    }

    static func from(keys: IdentityKeys) -> VeilIdentity? {
        guard let sp = Data(hexString: keys.signPriv),
              let xp = Data(hexString: keys.xPriv) else { return nil }
        guard let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: sp),
              let agreement = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: xp)
        else { return nil }
        let id = VeilIdentity(signing: signing, agreement: agreement)
        // если публичные части не совпадают с приватными — ключи повреждены
        guard id.signPubHex == keys.signPub.lowercased(),
              id.xPubHex == keys.xPub.lowercased() else { return nil }
        return id
    }
}

// MARK: - Crypto core

enum VeilCryptoError: Error {
    case invalidKey
    case invalidPayload
    case decryptFailed
}

enum VeilCrypto {
    /// Параметры KDF — должны в точности совпадать с реализацией в tests/interop.
    static let kdfSalt = Data("VEIL-SALT-V1".utf8)
    static let kdfInfoPrefix = "VEIL-CTX-V1"

    static func isValidHex64(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }

    /// Ключи направления для переписки двух сторон.
    ///
    /// X25519 static-static ECDH -> HKDF-SHA256 (64 байта) -> два ключа
    /// ChaChaPoly: ключ стороны с лексикографически меньшим sign-ключом —
    /// первые 32 байта, другой стороны — вторые 32. Это исключает
    /// повторное использование нонса между направлениями. Для «самопереписки»
    /// (Избранное) оба направления используют первый ключ.
    static func directionKeys(myXPriv: Curve25519.KeyAgreement.PrivateKey,
                              theirXPubHex: String,
                              mySignPubHex: String,
                              theirSignPubHex: String) throws -> (send: SymmetricKey, receive: SymmetricKey) {
        guard let pubData = Data(hexString: theirXPubHex), isValidHex64(theirXPubHex) else {
            throw VeilCryptoError.invalidKey
        }
        let theirPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubData)
        let shared = try myXPriv.sharedSecretFromKeyAgreement(with: theirPub)
        let ordered = [mySignPubHex, theirSignPubHex].sorted()
        let (lo, hi) = (ordered[0], ordered[1])
        let info = Data("\(kdfInfoPrefix):\(lo):\(hi)".utf8)
        let okm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: kdfSalt,
                                                 sharedInfo: info, outputByteCount: 64)
        let okmBytes = okm.withUnsafeBytes { [UInt8]($0) }
        let keyLo = SymmetricKey(data: Data(okmBytes[0..<32]))
        let keyHi = SymmetricKey(data: Data(okmBytes[32..<64]))
        if lo == hi { return (keyLo, keyLo) }
        return mySignPubHex == lo ? (keyLo, keyHi) : (keyHi, keyLo)
    }

    /// Шифрование: ChaCha20-Poly1305, случайный nonce. Формат: nonce(12) || ct || tag(16).
    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let nonceBytes = Data((0..<12).map { _ in UInt8.random(in: .min ... .max) })
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes)
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        return box.combined
    }

    static func open(_ payload: Data, key: SymmetricKey) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: payload)
        return try ChaChaPoly.open(box, using: key)
    }

    /// Подпись для аутентификации запросов к relay:
    /// Ed25519 поверх "<purpose>:<user_hex>:<unix_ts>:<nonce>", результат в base64.
    /// nonce обязателен: Ed25519 детерминирован, и без него две подписи
    /// в одну секунду совпали бы и были бы отброшены relay как replay.
    static func authSignature(purpose: String, user: String, ts: Int64, nonce: String,
                              signingKey: Curve25519.Signing.PrivateKey) -> String {
        let msg = Data("\(purpose):\(user):\(ts):\(nonce)".utf8)
        // подпись Ed25519 не падает на валидном ключе
        return (try? signingKey.signature(for: msg).base64EncodedString()) ?? ""
    }

    static func randomNonce() -> String {
        Data((0..<8).map { _ in UInt8.random(in: .min ... .max) }).hexString
    }

    /// Подпись отправителя поверх отправляемого конверта:
    /// Ed25519(raw(32 байта X25519-ключа) || ciphertext).
    static func envelopeSignature(xPubHex: String, payload: Data,
                                  signingKey: Curve25519.Signing.PrivateKey) -> String {
        guard let xData = Data(hexString: xPubHex) else { return "" }
        let msg = xData + payload
        return (try? signingKey.signature(for: msg).base64EncodedString()) ?? ""
    }

    static func verifyEnvelopeSignature(sig: Data, senderXPubHex: String, senderSignPubHex: String,
                                        payload: Data) -> Bool {
        guard isValidHex64(senderXPubHex), isValidHex64(senderSignPubHex),
              let xData = Data(hexString: senderXPubHex),
              let signData = Data(hexString: senderSignPubHex) else { return false }
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: signData) else {
            return false
        }
        return pub.isValidSignature(sig, for: xData + payload)
    }
}
