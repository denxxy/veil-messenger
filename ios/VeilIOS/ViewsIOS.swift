import SwiftUI
import UniformTypeIdentifiers

// iOS-интерфейс Veil. Написан на кросс-платформенном SwiftUI (iOS 16+ /
// macOS 13+): ios/build_check.sh компилирует этот же файл на macOS, так
// UI проверяется без Xcode. iOS-специфика спрятана в veilXxx-хелперы.

#if canImport(UIKit)
import UIKit
func veilCopy(_ s: String) { UIPasteboard.general.string = s }
func veilPaste() -> String? { UIPasteboard.general.string }
#else
import AppKit
func veilCopy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
func veilPaste() -> String? { NSPasteboard.general.string(forType: .string) }
#endif

extension View {
    /// Поле для ввода URL-адресов: телефонная клавиатура без автокапитализации.
    @ViewBuilder
    func veilURLInput() -> some View {
        #if canImport(UIKit)
        self.keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// Поле для кода приглашения: без автокапитализации и автозамены.
    @ViewBuilder
    func veilCodeInput() -> some View {
        #if canImport(UIKit)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    @ViewBuilder
    func veilInlineTitle() -> some View {
        #if canImport(UIKit)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

extension Color {
    /// Фон «чужого» пузыря сообщения.
    static func veilBubbleIncoming() -> Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

// MARK: - Корень

struct RootViewIOS: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if store.identity == nil {
            OnboardingViewIOS()
        } else {
            ChatListScreen()
        }
    }
}

// MARK: - Список чатов

struct ChatListScreen: View {
    @EnvironmentObject var store: AppStore
    @State private var showAddContact = false

    private var sortedContacts: [Contact] {
        store.contacts.sorted {
            ($0.lastMessageAt ?? 0) > ($1.lastMessageAt ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let me = store.selfContact {
                        NavigationLink(value: me.signPub) {
                            ChatRowIOS(contact: me, isSelfChat: true)
                        }
                    }
                    ForEach(sortedContacts) { contact in
                        NavigationLink(value: contact.signPub) {
                            ChatRowIOS(contact: contact)
                        }
                    }
                }
                Section("Настройки") {
                    NavigationLink(value: "profile") {
                        Label("Мой профиль", systemImage: "person.crop.circle")
                    }
                    NavigationLink(value: "relays") {
                        Label("Реле-серверы", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            }
            .navigationTitle("Veil")
            .navigationDestination(for: String.self) { value in
                if value == "profile" {
                    ProfileScreenIOS()
                } else if value == "relays" {
                    RelaysScreenIOS()
                } else {
                    ChatScreenIOS(contactId: value)
                }
            }
            .toolbar {
                Button {
                    showAddContact = true
                } label: {
                    Label("Добавить контакт", systemImage: "person.badge.plus")
                }
            }
            .sheet(isPresented: $showAddContact) { AddContactSheetIOS() }
        }
    }
}

struct ChatRowIOS: View {
    @EnvironmentObject var store: AppStore
    let contact: Contact
    var isSelfChat = false

    private var initials: String {
        if isSelfChat { return "★" }
        let parts = contact.name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(isSelfChat ? Color.orange.opacity(0.25)
                                         : Color.accentColor.opacity(0.18))
                Text(initials)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelfChat ? .orange : .accentColor)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(isSelfChat ? "Избранное" : contact.name).lineLimit(1)
                if let last = store.lastMessage(for: contact.signPub) {
                    Text(last.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Чат

struct ChatScreenIOS: View {
    @EnvironmentObject var store: AppStore
    let contactId: String
    @State private var input = ""

    private var contact: Contact? { store.contact(contactId) }

    var body: some View {
        VStack(spacing: 0) {
            if contact != nil {
                if let error = store.lastError {
                    errorBanner(error)
                }
                messageList
                inputBar
            } else {
                Spacer()
                Text("Чат недоступен").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .navigationTitle(contact.map { $0.signPub == store.mySignPub ? "Избранное" : $0.name } ?? "")
        .veilInlineTitle()
    }

    private func errorBanner(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.footnote)
            Spacer()
            Button {
                store.lastError = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.orange.opacity(0.15))
        .foregroundColor(.orange)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.messages(for: contactId)) { msg in
                        MessageBubbleIOS(message: msg).id(msg.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: store.messages.count) { _ in
                if let last = store.messages(for: contactId).last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = store.messages(for: contactId).last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Сообщение…", text: $input)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
    }

    private func send() {
        let text = input
        input = ""
        store.sendMessage(text, to: contactId)
    }
}

struct MessageBubbleIOS: View {
    let message: StoredMessage

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if !message.incoming { Spacer(minLength: 44) }
            VStack(alignment: message.incoming ? .leading : .trailing, spacing: 3) {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.incoming
                                ? Color.veilBubbleIncoming()
                                : Color.accentColor.opacity(0.85))
                    .foregroundStyle(message.incoming ? Color.primary : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                HStack(spacing: 4) {
                    Text(Self.timeFormatter.string(from: Date(timeIntervalSince1970: message.ts / 1000)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !message.incoming {
                        Text(message.delivered ? "✓✓" : "✓…")
                            .font(.caption2)
                            .foregroundStyle(message.delivered ? Color.accentColor : Color.secondary)
                    }
                }
            }
            if message.incoming { Spacer(minLength: 44) }
        }
    }
}

// MARK: - Профиль

struct ProfileScreenIOS: View {
    @EnvironmentObject var store: AppStore
    @State private var copied = false
    @State private var importError: String?
    @State private var showImporter = false

    private var inviteString: String? {
        guard let id = store.identity else { return nil }
        return Invite.encode(InvitePayload(v: 1, n: store.profileName,
                                           s: id.signPubHex, x: id.xPubHex,
                                           r: store.enabledRelayURLs))
    }

    var body: some View {
        Form {
            Section("Профиль") {
                TextField("Имя", text: $store.profileName)
            }
            if let id = store.identity {
                Section("Идентификация") {
                    Text(id.signPubHex)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Section("Приглашение") {
                    Text("Передайте код контакту любым каналом. По нему вас смогут добавить и написать — ничего больше.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let invite = inviteString {
                        ScrollView {
                            Text(invite)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.veilBubbleIncoming())
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 110)
                        ShareLink(item: invite, subject: Text("Приглашение Veil")) {
                            Label("Поделиться приглашением", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            veilCopy(invite)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                        } label: {
                            Label(copied ? "Скопировано" : "Скопировать код",
                                  systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        }
                    }
                }
                Section("Резервная копия") {
                    Text("Файл содержит приватные ключи: тот, кто его получит, сможет читать ваши сообщения.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let data = store.exportIdentityJSON() {
                        ShareLink(item: writeTempJSON(data),
                                  preview: SharePreview("veil-identity-backup.json")) {
                            Label("Экспортировать личность…", systemImage: "square.and.arrow.up.on.square")
                        }
                    }
                    Button("Импортировать…") { showImporter = true }
                    if let importError {
                        Text(importError).font(.caption).foregroundColor(.red)
                    }
                }
            }
        }
        .navigationTitle("Мой профиль")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                do {
                    let data = try Data(contentsOf: url)
                    guard let keys = try? JSONDecoder().decode(IdentityKeys.self, from: data),
                          store.importIdentity(keys: keys, name: "") else {
                        importError = "Файл не похож на резервную копию Veil"
                        return
                    }
                    importError = nil
                } catch {
                    importError = "Ошибка чтения: \(error.localizedDescription)"
                }
            case .failure:
                break
            }
        }
    }

    private func writeTempJSON(_ data: Data) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("veil-identity-backup.json")
        try? data.write(to: url)
        return url
    }
}

// MARK: - Реле

struct RelaysScreenIOS: View {
    @EnvironmentObject var store: AppStore
    @State private var showAdd = false

    var body: some View {
        Group {
            if store.relays.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("Ни одного relay не настроено")
                        .font(.headline)
                    Text("Relay — сервер-посредник: хранит зашифрованные конверты и не может прочитать сообщения.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else {
                List {
                    ForEach(store.relays) { relay in
                        RelayRowIOS(relay: relay)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            store.removeRelay(store.relays[index].id)
                        }
                    }
                }
            }
        }
        .navigationTitle("Реле-серверы")
        .toolbar {
            Button { showAdd = true } label: {
                Label("Добавить relay", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showAdd) { AddRelaySheetIOS() }
    }
}

struct RelayRowIOS: View {
    @EnvironmentObject var store: AppStore
    let relay: RelayConfig

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(relay.url)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(for: relay.lastStatus))
                        .frame(width: 7, height: 7)
                    Text(relay.lastStatus ?? "не проверен")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Проверить") {
                        let id = relay.id, url = relay.url
                        store.setRelayStatus(id, status: "проверка…")
                        Task {
                            let ok = await RelayService.shared.health(url)
                            await MainActor.run {
                                store.setRelayStatus(id, status: ok ? "онлайн" : "недоступен")
                            }
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { relay.enabled },
                set: { store.setRelayEnabled(relay.id, $0) }))
                .labelsHidden()
        }
        .onAppear {
            if relay.lastStatus == nil {
                let id = relay.id, url = relay.url
                Task {
                    let ok = await RelayService.shared.health(url)
                    await MainActor.run {
                        store.setRelayStatus(id, status: ok ? "онлайн" : "недоступен")
                    }
                }
            }
        }
    }

    private func color(for status: String?) -> Color {
        switch status {
        case "онлайн": return .green
        case "недоступен": return .red
        default: return .secondary.opacity(0.5)
        }
    }
}

struct AddRelaySheetIOS: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var checkResult: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("https://relay.example.com", text: $url)
                    .veilURLInput()
                    .onSubmit(check)
                if let checkResult {
                    Text(checkResult).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Проверить") { check() }
                        .disabled(url.isEmpty || checking)
                }
            }
            .navigationTitle("Добавить relay")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        if store.addRelay(rawURL: url) {
                            dismiss()
                        } else {
                            checkResult = "Не похоже на адрес"
                        }
                    }
                    .disabled(url.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func check() {
        checking = true
        checkResult = "проверяю…"
        let target = url
        Task {
            let ok = await RelayService.shared.health(target)
            await MainActor.run {
                checking = false
                checkResult = ok ? "✅ отвечает" : "❌ нет ответа (можно добавить и так)"
            }
        }
    }
}

// MARK: - Добавление контакта

struct AddContactSheetIOS: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var raw = ""

    private var invite: InvitePayload? { Invite.parse(raw) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Код приглашения") {
                    TextEditor(text: $raw)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 90)
                        .veilCodeInput()
                    Button {
                        if let s = veilPaste() { raw = s }
                    } label: {
                        Label("Вставить из буфера", systemImage: "doc.on.clipboard")
                    }
                }
                if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Просмотр") {
                        if let invite {
                            LabeledContent("Имя", value: invite.n.isEmpty ? "—" : invite.n)
                            LabeledContent("ID", value: String(invite.s.prefix(16)) + "…")
                            LabeledContent("Реле", value: invite.r.isEmpty ? "не указаны" : invite.r.joined(separator: ", "))
                        } else {
                            Label("Код не распознан", systemImage: "exclamationmark.triangle")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .navigationTitle("Добавить контакт")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        if let invite, store.addContact(invite) {
                            dismiss()
                        }
                    }
                    .disabled(invite == nil)
                }
            }
        }
    }
}

// MARK: - Онбординг

struct OnboardingViewIOS: View {
    @EnvironmentObject var store: AppStore
    @State private var name = ""

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("Veil")
                .font(.largeTitle.bold())
            Text("Мессенджер, устойчивый к блокировкам.\nКлючи создаются на устройстве и никогда не покидают его; relay видит только зашифрованные конверты.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            VStack(spacing: 10) {
                TextField("Ваше имя", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit { store.createIdentity(name: name) }
                    .veilCodeInput()
                Button {
                    store.createIdentity(name: name)
                } label: {
                    Label("Создать личность", systemImage: "key.horizontal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 32)
            Spacer()
            Text("Прототип v0.1 · экспериментальное ПО")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
