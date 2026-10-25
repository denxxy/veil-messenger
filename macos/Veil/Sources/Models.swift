import Foundation

// MARK: - Wire format

/// Открытый текст внутри конверта (после расшифровки).
/// `f` (sign-ключ) и `x` (X25519-ключ) отправителя дублируются в самом конверте,
/// но внутри шифротекста это позволяет получателю сверить целостность.
struct MessageInner: Codable, Equatable {
    let i: String      // уникальный id сообщения (для дедупликации)
    let t: String      // текст
    let ts: Double     // время отправки, мс
    let r: [String]    // relay-адреса отправителя (для ответа)
}

/// Зашифрованный конверт, который видит relay. Имена полей — wire-протокол v1.
struct OutgoingEnvelope: Codable {
    let to: String        // hex sign-ключ получателя (адрес «почтового ящика»)
    let from: String      // hex sign-ключ отправителя
    let fromX: String     // hex X25519-ключ отправителя
    let payload: String   // base64: nonce||ct||tag
    let sig: String       // base64: Ed25519(from_x || payload)

    enum CodingKeys: String, CodingKey {
        case to, from
        case fromX = "from_x"
        case payload, sig
    }
}

/// Конверт, полученный из relay (ответ GET /api/v1/inbox или WS push).
struct EnvelopeDTO: Codable {
    let id: String
    let sender: String
    let senderX: String
    let payload: String
    let sig: String
    let created: Double

    enum CodingKeys: String, CodingKey {
        case id, sender, payload, sig, created
        case senderX = "sender_x"
    }
}

struct InboxResponse: Codable {
    let envelopes: [EnvelopeDTO]
}

// MARK: - Contacts / chats / relays

struct Contact: Codable, Identifiable, Equatable {
    let signPub: String     // и есть id
    var name: String
    var xPub: String
    var relays: [String]
    let addedAt: Double
    var lastMessageAt: Double?

    var id: String { signPub }
    var shortID: String { String(signPub.prefix(8)) }
}

struct StoredMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let contactId: String
    let incoming: Bool
    let text: String
    let ts: Double                  // мс, по часам отправителя
    var delivered: Bool
    let remoteId: String            // MessageInner.i
}

struct RelayConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var url: String
    var enabled: Bool
    var lastStatus: String?

    init(url: String, enabled: Bool = true) {
        self.id = UUID()
        self.url = url
        self.enabled = enabled
        self.lastStatus = nil
    }
}

// MARK: - Invites

struct InvitePayload: Codable, Equatable {
    let v: Int
    let n: String      // имя
    let s: String      // hex sign-ключ
    let x: String      // hex X25519-ключ
    let r: [String]    // relay-адреса владельца
}

enum Invite {
    static let prefix = "veil-invite:v1:"

    static func encode(_ payload: InvitePayload) -> String {
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return prefix + Base64URL.encode(data)
    }

    /// Принимает строку с кодом приглашения (можно с лишними пробелами).
    static func parse(_ raw: String) -> InvitePayload? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: prefix) {
            s = String(s[range.upperBound...])
        }
        guard let data = Base64URL.decode(s) else { return nil }
        guard let payload = try? JSONDecoder().decode(InvitePayload.self, from: data) else {
            return nil
        }
        guard payload.v == 1,
              VeilCrypto.isValidHex64(payload.s),
              VeilCrypto.isValidHex64(payload.x) else { return nil }
        return payload
    }
}
