import CryptoKit
import Foundation

/// Всё состояние приложения, сохраняемое в ~/Library/Application Support/Veil/store.json.
/// Файл создаётся с правами 0600: там же лежат приватные ключи и локальная история.
struct PersistedState: Codable {
    var profileName: String = ""
    var contacts: [Contact] = []
    var messages: [StoredMessage] = []
    var relays: [RelayConfig] = []
    var identityKeys: IdentityKeys?
    var createdAt: Double = Date().timeIntervalSince1970
}

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published private(set) var identity: VeilIdentity?
    @Published var profileName = "" { didSet { scheduleSave() } }
    @Published var contacts: [Contact] = [] { didSet { scheduleSave() } }
    @Published var messages: [StoredMessage] = [] { didSet { scheduleSave() } }
    @Published var relays: [RelayConfig] = [] { didSet { scheduleSave() } }
    @Published var lastError: String?

    private let stateURL: URL
    private var saveTask: Task<Void, Never>?
    private var bootstrapped = false

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Veil", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateURL = dir.appendingPathComponent("store.json")
    }

    // MARK: - Persistence

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        profileName = state.profileName
        contacts = state.contacts
        messages = state.messages
        relays = state.relays
        if let keys = state.identityKeys {
            identity = VeilIdentity.from(keys: keys)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { self?.saveNow() }
        }
    }

    func saveNow() {
        guard let keys = identity?.keys else { return }
        let state = PersistedState(profileName: profileName, contacts: contacts,
                                   messages: messages, relays: relays,
                                   identityKeys: keys, createdAt: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: stateURL.path)
    }

    // MARK: - Identity

    func createIdentity(name: String) {
        let identity = VeilIdentity.generate()
        self.identity = identity
        profileName = name.isEmpty ? "Я" : name
        saveNow()
    }

    func importIdentity(keys: IdentityKeys, name: String) -> Bool {
        guard let identity = VeilIdentity.from(keys: keys) else { return false }
        self.identity = identity
        if !name.isEmpty { profileName = name }
        saveNow()
        return true
    }

    var mySignPub: String? { identity?.signPubHex }

    /// Контакт «сам у себя» для чата-заметок «Избранное».
    var selfContact: Contact? {
        guard let id = identity else { return nil }
        return Contact(signPub: id.signPubHex, name: profileName.isEmpty ? "Избранное" : profileName,
                       xPub: id.xPubHex, relays: relays.filter(\.enabled).map(\.url),
                       addedAt: 0, lastMessageAt: nil)
    }

    var enabledRelayURLs: [String] {
        relays.filter(\.enabled).map { RelayService.normalizeBase($0.url) }
    }

    // MARK: - Contacts

    func contact(_ signPub: String) -> Contact? {
        signPub == identity?.signPubHex ? selfContact : contacts.first { $0.signPub == signPub }
    }

    func addContact(_ invite: InvitePayload) -> Bool {
        guard let myPub = identity?.signPubHex, invite.s != myPub else { return false }
        guard contacts.first(where: { $0.signPub == invite.s }) == nil else {
            // контакт уже есть — обновим relay-адреса, если старые пусты
            if let idx = contacts.firstIndex(where: { $0.signPub == invite.s }),
               contacts[idx].relays.isEmpty, !invite.r.isEmpty {
                contacts[idx].relays = invite.r
            }
            return true
        }
        contacts.append(Contact(signPub: invite.s,
                                name: invite.n.isEmpty ? "Контакт · " + String(invite.s.prefix(8)) : invite.n,
                                xPub: invite.x, relays: invite.r,
                                addedAt: Date().timeIntervalSince1970,
                                lastMessageAt: nil))
        return true
    }

    func renameContact(_ signPub: String, to name: String) {
        guard let idx = contacts.firstIndex(where: { $0.signPub == signPub }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        contacts[idx].name = trimmed
    }

    func removeContact(_ signPub: String) {
        contacts.removeAll { $0.signPub == signPub }
        messages.removeAll { $0.contactId == signPub }
    }

    // MARK: - Relays

    func addRelay(rawURL: String) -> Bool {
        let base = RelayService.normalizeBase(rawURL)
        guard URL(string: base) != nil, base.count > "https://".count + 2 else { return false }
        guard relays.first(where: { RelayService.normalizeBase($0.url) == base }) == nil else {
            return true // уже добавлен
        }
        relays.append(RelayConfig(url: base))
        return true
    }

    func setRelayEnabled(_ id: UUID, _ enabled: Bool) {
        guard let idx = relays.firstIndex(where: { $0.id == id }) else { return }
        relays[idx].enabled = enabled
    }

    func setRelayStatus(_ id: UUID, status: String) {
        guard let idx = relays.firstIndex(where: { $0.id == id }) else { return }
        relays[idx].lastStatus = status
    }

    func removeRelay(_ id: UUID) {
        relays.removeAll { $0.id == id }
    }

    // MARK: - Messages

    func messages(for contactId: String) -> [StoredMessage] {
        messages.filter { $0.contactId == contactId }.sorted { $0.ts < $1.ts }
    }

    func lastMessage(for contactId: String) -> StoredMessage? {
        messages(for: contactId).last
    }

    func sendMessage(_ text: String, to contactId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let identity else { return }
        let innerId = UUID().uuidString
        let ts = Date().timeIntervalSince1970 * 1000

        // адресуем на relay контакта; если их нет — на свои (в т.ч. для «Избранного»)
        let contactRelays = contact(contactId)?.relays ?? []
        let targets = contactId == identity.signPubHex || contactRelays.isEmpty
            ? enabledRelayURLs : contactRelays
        guard !targets.isEmpty else {
            lastError = "Не настроен ни один relay — добавьте его в разделе «Реле»"
            return
        }

        let inner = MessageInner(i: innerId, t: trimmed, ts: ts, r: enabledRelayURLs)
        guard let envelope = buildEnvelope(inner: inner, to: contactId) else {
            lastError = "Не удалось зашифровать сообщение"
            return
        }
        messages.append(StoredMessage(id: UUID(), contactId: contactId, incoming: false,
                                      text: trimmed, ts: ts, delivered: false, remoteId: innerId))
        Task { [weak self] in
            let ok = await RelayService.shared.deliver(envelope: envelope, to: targets)
            await MainActor.run { self?.markDelivery(remoteId: innerId, delivered: ok) }
        }
    }

    /// Шифрует и подписывает inner-сообщение. Возвращает готовый конверт.
    private func buildEnvelope(inner: MessageInner, to contactId: String) -> OutgoingEnvelope? {
        guard let identity,
              let recipient = contact(contactId),
              let innerData = try? JSONEncoder().encode(inner) else { return nil }
        guard let keys = try? VeilCrypto.directionKeys(
            myXPriv: identity.agreement,
            theirXPubHex: recipient.xPub,
            mySignPubHex: identity.signPubHex,
            theirSignPubHex: contactId) else { return nil }
        guard let sealed = try? VeilCrypto.seal(innerData, key: keys.send) else { return nil }
        let sig = VeilCrypto.envelopeSignature(xPubHex: identity.xPubHex, payload: sealed,
                                               signingKey: identity.signing)
        return OutgoingEnvelope(to: contactId, from: identity.signPubHex,
                                fromX: identity.xPubHex,
                                payload: sealed.base64EncodedString(), sig: sig)
    }

    private func markDelivery(remoteId: String, delivered: Bool) {
        guard let idx = messages.firstIndex(where: { $0.remoteId == remoteId && !$0.incoming })
        else { return }
        messages[idx].delivered = delivered
    }

    /// Повторная отправка недоставленных сообщений (вызывается сервисом по таймеру).
    func resendPending() {
        guard let identity else { return }
        let pending = messages.filter { !$0.incoming && !$0.delivered }
        guard !pending.isEmpty else { return }
        for msg in pending {
            guard msg.contactId == identity.signPubHex || contact(msg.contactId) != nil else { continue }
            let inner = MessageInner(i: msg.remoteId, t: msg.text, ts: msg.ts,
                                     r: enabledRelayURLs)
            guard let envelope = buildEnvelope(inner: inner, to: msg.contactId) else { continue }
            let contactRelays = contact(msg.contactId)?.relays ?? []
            let targets = msg.contactId == identity.signPubHex || contactRelays.isEmpty
                ? enabledRelayURLs : contactRelays
            guard !targets.isEmpty else { continue }
            Task { [weak self] in
                let ok = await RelayService.shared.deliver(envelope: envelope, to: targets)
                await MainActor.run { self?.markDelivery(remoteId: msg.remoteId, delivered: ok) }
            }
        }
    }

    // MARK: - Incoming

    func handleIncoming(_ env: EnvelopeDTO) {
        guard let identity else { return }
        guard VeilCrypto.isValidHex64(env.sender), VeilCrypto.isValidHex64(env.senderX),
              let payload = Data(base64Encoded: env.payload),
              let sig = Data(base64Encoded: env.sig) else { return }

        // 1. Подпись отправителя связывает его Ed25519-ключ с X25519-ключом и шифротекстом.
        guard VeilCrypto.verifyEnvelopeSignature(sig: sig, senderXPubHex: env.senderX,
                                                 senderSignPubHex: env.sender, payload: payload)
        else { return }

        // 2. Расшифровка своим ключом направления.
        guard let keys = try? VeilCrypto.directionKeys(
                myXPriv: identity.agreement,
                theirXPubHex: env.senderX,
                mySignPubHex: identity.signPubHex,
                theirSignPubHex: env.sender),
              let plain = try? VeilCrypto.open(payload, key: keys.receive),
              let inner = try? JSONDecoder().decode(MessageInner.self, from: plain)
        else { return }

        let isSelf = env.sender == identity.signPubHex
        let chatId = isSelf ? identity.signPubHex : env.sender

        // 3. Дедупликация по inner.i (WS push + polling могут доставить дважды).
        if let idx = messages.firstIndex(where: { $0.remoteId == inner.i && $0.contactId == chatId }) {
            if !messages[idx].incoming { messages[idx].delivered = true }
            return
        }

        // 4. Неизвестный отправитель -> авто-контакт (relay-адреса берём из сообщения).
        if !isSelf {
            if let idx = contacts.firstIndex(where: { $0.signPub == env.sender }) {
                if contacts[idx].xPub != env.senderX { contacts[idx].xPub = env.senderX }
                if contacts[idx].relays.isEmpty, !inner.r.isEmpty { contacts[idx].relays = inner.r }
            } else {
                contacts.append(Contact(signPub: env.sender,
                                        name: "Неизвестный · " + String(env.sender.prefix(8)),
                                        xPub: env.senderX, relays: inner.r,
                                        addedAt: Date().timeIntervalSince1970,
                                        lastMessageAt: inner.ts))
            }
        }

        messages.append(StoredMessage(id: UUID(), contactId: chatId,
                                      incoming: !isSelf, text: inner.t, ts: inner.ts,
                                      delivered: true, remoteId: inner.i))
        if let idx = contacts.firstIndex(where: { $0.signPub == env.sender }) {
            contacts[idx].lastMessageAt = inner.ts
        }
    }

    // MARK: - Backup

    func exportIdentityJSON() -> Data? {
        guard let keys = identity?.keys else { return nil }
        return try? JSONEncoder().encode(keys)
    }
}
