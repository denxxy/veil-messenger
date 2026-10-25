import AppKit
import SwiftUI

// MARK: - Мой профиль

struct ProfileView: View {
    @EnvironmentObject var store: AppStore
    @State private var copied = false
    @State private var importError: String?

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
                    LabeledContent("ID") {
                        Text(id.signPubHex)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                Section("Приглашение") {
                    Text("Передайте этот код контакту любым каналом (мессенджер, почта, QR). По нему вас смогут добавить и написать — ничего больше.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(inviteString ?? "")
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .textSelection(.enabled)
                    }
                    .frame(height: 90)
                    HStack {
                        Button {
                            if let s = inviteString {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(s, forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                                    copied = false
                                }
                            }
                        } label: {
                            Label(copied ? "Скопировано" : "Скопировать код приглашения",
                                  systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        }
                        Spacer()
                    }
                }

                Section("Резервная копия") {
                    Text("Файл содержит приватные ключи: тот, кто его получит, сможет читать ваши сообщения. Храните его только на надёжных носителях.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Экспортировать личность…") { exportIdentity() }
                        Button("Импортировать…") { importIdentity() }
                    }
                    if let importError {
                        Text(importError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Мой профиль")
        .frame(minWidth: 480)
    }

    private func exportIdentity() {
        guard let data = store.exportIdentityJSON() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "veil-identity-backup.json"
        panel.message = "Файл содержит приватные ключи — храните его в безопасности."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                store.lastError = "Не удалось записать файл: \(error.localizedDescription)"
            }
        }
    }

    private func importIdentity() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
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
        }
    }
}

// MARK: - Реле

struct RelaysView: View {
    @EnvironmentObject var store: AppStore
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 0) {
            if store.relays.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("Ни одного relay не настроено")
                        .font(.headline)
                    Text("Relay — это сервер-посредник: он хранит зашифрованные конверты\nи не может прочитать сообщения. Можно использовать несколько relay,\nвключая собственный на VPS.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.relays) { relay in
                        RelayRowView(relay: relay)
                            .contextMenu {
                                Button("Удалить", role: .destructive) {
                                    store.removeRelay(relay.id)
                                }
                            }
                    }
                }
            }
        }
        .toolbar {
            Button { showAdd = true } label: {
                Label("Добавить relay", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showAdd) { AddRelaySheet() }
        .navigationTitle("Реле-серверы")
        .frame(minWidth: 480)
    }
}

struct RelayRowView: View {
    @EnvironmentObject var store: AppStore
    let relay: RelayConfig

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(relay.url)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Circle()
                        .fill(colorFor(status: relay.lastStatus))
                        .frame(width: 7, height: 7)
                    Text(relay.lastStatus ?? "не проверен")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Проверить") {
                        let id = relay.id
                        let url = relay.url
                        store.setRelayStatus(id, status: "проверка…")
                        Task {
                            let ok = await RelayService.shared.health(url)
                            await MainActor.run {
                                store.setRelayStatus(id, status: ok ? "онлайн" : "недоступен")
                            }
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.link)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { relay.enabled },
                set: { store.setRelayEnabled(relay.id, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Использовать этот relay")
        }
        .padding(.vertical, 3)
        .onAppear {
            if relay.lastStatus == nil {
                let id = relay.id
                let url = relay.url
                Task {
                    let ok = await RelayService.shared.health(url)
                    await MainActor.run {
                        store.setRelayStatus(id, status: ok ? "онлайн" : "недоступен")
                    }
                }
            }
        }
    }

    private func colorFor(status: String?) -> Color {
        switch status {
        case "онлайн": return .green
        case "недоступен": return .red
        default: return .secondary.opacity(0.5)
        }
    }
}

struct AddRelaySheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var checkResult: String?
    @State private var checking = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Добавить relay").font(.headline)
            TextField("https://relay.example.com", text: $url)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 380)
                .onSubmit(check)
            if let checkResult {
                Text(checkResult).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Проверить") { check() }
                    .disabled(url.isEmpty || checking)
                Spacer()
                Button("Добавить") {
                    if store.addRelay(rawURL: url) {
                        dismiss()
                    } else {
                        checkResult = "Не похоже на адрес"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.isEmpty)
                .buttonStyle(.borderedProminent)
                Button("Отмена") { dismiss() }
            }
        }
        .padding(20)
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

struct AddContactSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var raw = ""

    private var invite: InvitePayload? { Invite.parse(raw) }

    var body: some View {
        VStack(spacing: 14) {
            Text("Добавить контакт").font(.headline)
            Text("Вставьте код приглашения, который вам передал человек")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $raw)
                .font(.system(.caption, design: .monospaced))
                .frame(minWidth: 420, minHeight: 90)
                .border(Color(nsColor: .separatorColor))
            if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let invite {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Имя: \(invite.n.isEmpty ? "—" : invite.n)")
                        Text("ID: \(invite.s.prefix(16))…")
                        Text("Реле: \(invite.r.isEmpty ? "не указаны" : invite.r.joined(separator: ", "))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Код не распознан").font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Добавить") {
                    if let invite, store.addContact(invite) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(invite == nil)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}
