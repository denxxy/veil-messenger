import SwiftUI

// MARK: - Root / навигация

enum SidebarSelection: Hashable {
    case chat(String)
    case profile
    case relays
}

struct RootView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if store.identity == nil {
            OnboardingView()
        } else {
            MainView()
        }
    }
}

struct MainView: View {
    @EnvironmentObject var store: AppStore
    @State private var selection: SidebarSelection?
    @State private var showAddContact = false

    private var sortedContacts: [Contact] {
        store.contacts.sorted {
            ($0.lastMessageAt ?? 0) > ($1.lastMessageAt ?? 0)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Чаты") {
                    if let me = store.selfContact {
                        ChatRow(contact: me, isSelfChat: true)
                            .tag(SidebarSelection.chat(me.signPub))
                    }
                    ForEach(sortedContacts) { contact in
                        ChatRow(contact: contact)
                            .tag(SidebarSelection.chat(contact.signPub))
                    }
                }
                Section("Настройки") {
                    Label("Мой профиль", systemImage: "person.crop.circle")
                        .tag(SidebarSelection.profile)
                    Label("Реле-серверы", systemImage: "antenna.radiowaves.left.and.right")
                        .tag(SidebarSelection.relays)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 340)
        } detail: {
            switch selection {
            case .chat(let id):
                ChatView(contactId: id)
            case .profile:
                ProfileView()
            case .relays:
                RelaysView()
            case nil:
                WelcomeView()
            }
        }
        .toolbar {
            Button {
                showAddContact = true
            } label: {
                Label("Добавить контакт", systemImage: "person.badge.plus")
            }
        }
        .sheet(isPresented: $showAddContact) {
            AddContactSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .veilShowAddContact)) { _ in
            showAddContact = true
        }
    }
}

struct ChatRow: View {
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
                    .foregroundStyle(isSelfChat ? .orange : .accentColor)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(isSelfChat ? "Избранное" : contact.name)
                    .lineLimit(1)
                if let last = store.lastMessage(for: contact.signPub) {
                    Text(last.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Veil")
                .font(.title.bold())
            Text("Выберите чат слева или добавьте контакт.\nСвободный обмен ключами — по коду приглашения в «Мой профиль».")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Чат

struct ChatView: View {
    @EnvironmentObject var store: AppStore
    let contactId: String
    @State private var input = ""

    private var contact: Contact? { store.contact(contactId) }

    var body: some View {
        VStack(spacing: 0) {
            if let contact {
                header(contact)
                Divider()
                if let error = store.lastError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error).font(.callout)
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
                    .foregroundStyle(.orange)
                }
                messageList
                Divider()
                inputBar
            } else {
                WelcomeView()
            }
        }
        .navigationTitle(contact.map { $0.signPub == store.mySignPub ? "Избранное" : $0.name } ?? "")
    }

    private func header(_ contact: Contact) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.18))
                Text(String(contact.name.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.signPub == store.mySignPub ? "Избранное" : contact.name)
                    .font(.headline)
                Text("ID: \(contact.shortID)… · реле: \(contact.relays.isEmpty ? "мои" : String(contact.relays.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.messages(for: contactId)) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                }
                .padding(14)
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
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private func send() {
        let text = input
        input = ""
        store.sendMessage(text, to: contactId)
    }
}

struct MessageBubble: View {
    let message: StoredMessage

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if !message.incoming { Spacer(minLength: 56) }
            VStack(alignment: message.incoming ? .leading : .trailing, spacing: 3) {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.incoming
                                ? Color(nsColor: .controlBackgroundColor)
                                : Color.accentColor.opacity(0.85))
                    .foregroundStyle(message.incoming ? Color.primary : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 4) {
                    Text(Self.timeFormatter.string(from: Date(timeIntervalSince1970: message.ts / 1000)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !message.incoming {
                        Text(message.delivered ? "✓✓" : "✓…")
                            .font(.caption2)
                            .foregroundStyle(message.delivered ? Color.accentColor : .secondary)
                    }
                }
            }
            if message.incoming { Spacer(minLength: 56) }
        }
    }
}
