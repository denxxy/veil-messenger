import AppKit
import SwiftUI

// MARK: - Тёмная карточка

struct VeilCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.vText)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.vPanel)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Моноширинная плашка ключа/invite на затенённом фоне.
struct VeilMonoTile: View {
    let text: String
    var maxHeight: CGFloat? = nil
    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color.vText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.vBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxHeight: maxHeight)
    }
}

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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let id = store.identity {
                    // Герой профиля
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().fill(VeilGradient.brand)
                                .frame(width: 64, height: 64)
                                .shadow(color: Color.vAccent.opacity(0.4), radius: 14, y: 6)
                            Text(initials)
                                .font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                        }
                        TextField("Имя", text: $store.profileName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color.vText)
                        if copied { Spacer(); Image(systemName: "checkmark").foregroundStyle(Color.vAccent) }
                    }
                    .padding(18)
                    .background(Color.vPanel)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.06)))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VeilCard(title: "Ваш ID") {
                        VStack(alignment: .leading, spacing: 10) {
                            VeilMonoTile(text: id.signPubHex)
                            Button { copyInvite() } label: {
                                Label(copied ? "Скопировано" : "Скопировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .buttonStyle(VeilPrimaryButtonStyle())
                        }
                    }

                    VeilCard(title: "Код приглашения") {
                        VStack(alignment: .leading, spacing: 10) {
                            VeilMonoTile(text: inviteString ?? "", maxHeight: 64)
                            Button { copyInvite() } label: {
                                Label(copied ? "Скопировано" : "Скопировать код", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .buttonStyle(VeilPrimaryButtonStyle())
                        }
                    }

                    VeilCard(title: "Резервная копия") {
                        HStack(spacing: 10) {
                            Button("⇩  Экспортировать личность…") { exportIdentity() }
                            Button("⇧  Импортировать…") { importIdentity() }
                        }
                        .buttonStyle(.bordered)
                        if let importError {
                            Text(importError).font(.caption).foregroundStyle(Color.vAccent)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 680)
        }
        .frame(maxWidth: .infinity)
        .background(Color.vBgRaised)
        .navigationTitle("Мой профиль")
    }

    private var initials: String {
        let n = store.profileName.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Я" }
        return String(n.split(separator: " ").prefix(2).compactMap { $0.first }).uppercased()
    }

    private func copyInvite() {
        guard let s = inviteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    private func exportIdentity() {
        guard let data = store.exportIdentityJSON() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "veil-identity-backup.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url, options: .atomic) }
            catch { store.lastError = "Не удалось записать файл: \(error.localizedDescription)" }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.relays.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 42)).foregroundStyle(Color.vAccent)
                        Text("Ещё нет реле").font(.system(size: 18, weight: .semibold))
                        Text("Добавьте свой сервер — и переписка заработает")
                            .font(.system(size: 14)).foregroundStyle(Color.vMuted)
                        Button { showAdd = true } label: {
                            Label("Добавить relay", systemImage: "plus")
                        }
                        .buttonStyle(VeilPrimaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 70)
                } else {
                    ForEach(store.relays) { relay in
                        RelayRowView(relay: relay)
                            .contextMenu {
                                Button("Удалить", role: .destructive) { store.removeRelay(relay.id) }
                            }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 680)
        }
        .frame(maxWidth: .infinity)
        .background(Color.vBgRaised)
        .toolbar {
            Button { showAdd = true } label: { Label("Добавить relay", systemImage: "plus") }
        }
        .sheet(isPresented: $showAdd) { AddRelaySheet() }
        .navigationTitle("Реле-серверы")
    }
}

struct RelayRowView: View {
    @EnvironmentObject var store: AppStore
    let relay: RelayConfig

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(relay.lastStatus == "недоступен" ? Color.vMuted : Color.vAccent)
                .frame(width: 10, height: 10)
            Text(relay.url)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(Color.vText)
            Spacer()
            Button("Проверить") {
                let id = relay.id
                let url = relay.url
                store.setRelayStatus(id, status: "проверка…")
                Task {
                    let ok = await RelayService.shared.health(url)
                    await MainActor.run { store.setRelayStatus(id, status: ok ? "онлайн" : "недоступен") }
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .tint(Color.vAccent)
            Toggle("", isOn: Binding(
                get: { relay.enabled },
                set: { store.setRelayEnabled(relay.id, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Color.vAccent)
        }
        .padding(16)
        .background(Color.vPanel)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            if relay.lastStatus == nil {
                let id = relay.id
                let url = relay.url
                Task {
                    let ok = await RelayService.shared.health(url)
                    await MainActor.run { store.setRelayStatus(id, status: ok ? "онлайн" : "недоступен") }
                }
            }
        }
    }
}

// MARK: - Листы (sheets)

struct AddRelaySheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var checkResult: String?
    @State private var checking = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Color.vAccent)
                Text("Добавить relay").font(.headline)
                Spacer()
            }
            TextField("https://relay.example.com", text: $url)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color.vText)
                .padding(12)
                .background(Color.vField)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onSubmit(check)
            if let checkResult {
                Text(checkResult).font(.system(size: 13)).foregroundStyle(Color.vMuted)
            }
            HStack {
                Button("Проверить") { check() }.disabled(url.isEmpty || checking)
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Добавить") {
                    if store.addRelay(rawURL: url) { dismiss() }
                    else { checkResult = "Не похоже на адрес" }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.isEmpty)
                .buttonStyle(VeilPrimaryButtonStyle())
            }
        }
        .padding(22)
        .frame(minWidth: 400)
        .background(Color.vPanel)
    }

    private func check() {
        checking = true
        checkResult = "проверяю…"
        let target = url
        Task {
            let ok = await RelayService.shared.health(target)
            await MainActor.run {
                checking = false
                checkResult = ok ? "Отвечает" : "Нет ответа"
            }
        }
    }
}

struct AddContactSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var raw = ""

    private var invite: InvitePayload? { Invite.parse(raw) }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(Color.vAccent)
                Text("Добавить контакт").font(.headline)
                Spacer()
            }
            TextField("Вставьте код приглашения", text: $raw, axis: .vertical)
                .lineLimit(4, reservesSpace: true)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.vText)
                .padding(10)
                .background(Color.vField)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let invite {
                    HStack(spacing: 8) {
                        VeilAvatar(name: invite.n.isEmpty ? "К" : invite.n, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(invite.n.isEmpty ? "Контакт" : invite.n)
                                .font(.system(size: 15, weight: .semibold))
                            Text("Готов к переписке")
                                .font(.system(size: 13)).foregroundStyle(Color.vMuted)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.vAccent)
                    }
                    .padding(14)
                    .background(Color.vAccent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Text("Код не распознан").font(.system(size: 13)).foregroundStyle(Color.vAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Добавить") {
                    if let invite, store.addContact(invite) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(invite == nil)
                .buttonStyle(VeilPrimaryButtonStyle())
            }
        }
        .padding(22)
        .background(Color.vPanel)
    }
}