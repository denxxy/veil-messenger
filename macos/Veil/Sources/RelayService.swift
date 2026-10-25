import CryptoKit
import Foundation

/// Сетевой слой: доставка конвертов, poll-получение входящих, WebSocket-каналы
/// и ретраи. Все запросы подписываются Ed25519-ключом identity.
final class RelayService {
    static let shared = RelayService()

    private var session: URLSession
    private var store: AppStore?
    private var pollTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var wsTasks: [UUID: Task<Void, Never>] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var attached = false

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func attach(store: AppStore) {
        self.store = store
        guard !attached else { return }
        attached = true
        pollTask = Task { await pollLoop() }
        retryTask = Task { await retryLoop() }
        wsSupervisor()
    }

    // MARK: - URL helpers

    static func normalizeBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
            s = "https://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func wsURL(_ base: String) -> String {
        var s = normalizeBase(base)
        if s.hasPrefix("https://") {
            s.replaceSubrange(s.startIndex..<s.index(s.startIndex, offsetBy: 8),
                              with: "wss://")
        } else if s.hasPrefix("http://") {
            s.replaceSubrange(s.startIndex..<s.index(s.startIndex, offsetBy: 7),
                              with: "ws://")
        }
        return s + "/api/v1/ws"
    }

    // MARK: - Delivery

    /// Пытается доставить конверт на каждый relay по очереди. true — хотя бы один принял.
    func deliver(envelope: OutgoingEnvelope, to bases: [String]) async -> Bool {
        guard let body = try? encoder.encode(envelope) else { return false }
        for base in bases {
            guard let url = URL(string: Self.normalizeBase(base) + "/api/v1/envelopes") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 12
            req.httpBody = body
            do {
                let (_, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return true
                }
            } catch {
                continue
            }
        }
        return false
    }

    /// Проверка доступности relay (GET /health).
    func health(_ rawBase: String) async -> Bool {
        guard let url = URL(string: Self.normalizeBase(rawBase) + "/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        do {
            let (_, resp) = try await session.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Inbox polling

    private func authHeaders(purpose: String, user: String,
                             key: Curve25519.Signing.PrivateKey) -> [String: String] {
        let ts = Int64(Date().timeIntervalSince1970)
        let nonce = VeilCrypto.randomNonce()
        return [
            "X-Veil-User": user,
            "X-Veil-Timestamp": String(ts),
            "X-Veil-Nonce": nonce,
            "X-Veil-Signature": VeilCrypto.authSignature(purpose: purpose, user: user,
                                                         ts: ts, nonce: nonce,
                                                         signingKey: key),
        ]
    }

    private func fetchInbox(base: String, user: String,
                            key: Curve25519.Signing.PrivateKey) async -> [EnvelopeDTO]? {
        guard let url = URL(string: Self.normalizeBase(base) + "/api/v1/inbox") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        for (k, v) in authHeaders(purpose: "inbox", user: user, key: key) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try decoder.decode(InboxResponse.self, from: data).envelopes
        } catch {
            return nil
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            var delay = 6.0
            if let store, let identity = await store.identity {
                let relays = await store.relays.filter(\.enabled)
                if !relays.isEmpty {
                    for relay in relays {
                        guard !Task.isCancelled else { break }
                        if let envelopes = await fetchInbox(base: relay.url,
                                                            user: identity.signPubHex,
                                                            key: identity.signing) {
                            for env in envelopes {
                                await store.handleIncoming(env)
                            }
                        }
                    }
                    // случайный джиттер, чтобы трафик не выглядел механическим
                    delay = 4.0 + Double.random(in: 0...5)
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func retryLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let store else { continue }
            await store.resendPending()
        }
    }

    // MARK: - WebSocket live-каналы

    /// На каждый включённый relay — супервизор, который держит соединение
    /// и переподключается с задержкой.
    private func wsSupervisor() {
        Task { [weak self] in
            while !Task.isCancelled {
                if let store = self?.store, let identity = await store.identity {
                    let relays = await store.relays.filter(\.enabled)
                    let live = Set(relays.map(\.id))
                    // остановить supervisor'ы отключённых relay
                    for (id, task) in self?.wsTasks ?? [:] where !live.contains(id) {
                        task.cancel()
                        self?.wsTasks[id] = nil
                    }
                    for relay in relays where self?.wsTasks[relay.id] == nil {
                        let id = relay.id
                        self?.wsTasks[id] = Task { [weak self] in
                            await self?.wsLoop(base: relay.url, relayID: id,
                                               user: identity.signPubHex,
                                               key: identity.signing)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func wsLoop(base: String, relayID: UUID, user: String,
                        key: Curve25519.Signing.PrivateKey) async {
        // identity может обновиться (импорт ключей) — на каждой итерации берём свежий
        while !Task.isCancelled {
            if let store, let identity = await store.identity {
                do {
                    try await runWS(base: base, user: identity.signPubHex,
                                    key: identity.signing)
                } catch {
                    // соединение оборвалось — чуть подождём и снова
                }
            }
            try? await Task.sleep(nanoseconds: UInt64((5 + Double.random(in: 0...8))
                                                      * 1_000_000_000))
        }
        wsTasks[relayID] = nil
    }

    private func runWS(base: String, user: String,
                       key: Curve25519.Signing.PrivateKey) async throws {
        guard let url = URL(string: Self.wsURL(base)) else { return }
        let task = session.webSocketTask(with: url)
        task.resume()

        let ts = Int64(Date().timeIntervalSince1970)
        let nonce = VeilCrypto.randomNonce()
        let auth: [String: Any] = [
            "type": "auth",
            "user": user,
            "ts": ts,
            "nonce": nonce,
            "signature": VeilCrypto.authSignature(purpose: "ws", user: user,
                                                  ts: ts, nonce: nonce,
                                                  signingKey: key),
        ]
        let authData = try JSONSerialization.data(withJSONObject: auth)
        try await task.send(.string(String(data: authData, encoding: .utf8) ?? "{}"))

        while !Task.isCancelled {
            let msg = try await task.receive()
            switch msg {
            case .string(let text):
                handleWSText(text)
            case .data(let data):
                handleWSText(String(data: data, encoding: .utf8) ?? "")
            @unknown default:
                break
            }
        }
    }

    private func handleWSText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? decoder.decode(WSFrame.self, from: data),
              obj.type == "envelope", let env = obj.envelope
        else { return }
        Task { [weak self] in
            guard let store = self?.store else { return }
            await store.handleIncoming(env)
        }
    }
}

struct WSFrame: Codable {
    let type: String
    var envelope: EnvelopeDTO?
}
