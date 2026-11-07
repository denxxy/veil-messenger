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
        Group {
            if store.identity == nil {
                OnboardingView()
            } else {
                MainView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct MainView: View {
    @EnvironmentObject var store: AppStore
    @State private var selection: SidebarSelection?
    @State private var showAddContact = false

    private var sortedContacts: [Contact] {
        store.contacts.sorted { ($0.lastMessageAt ?? 0) > ($1.lastMessageAt ?? 0) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 258, max: 330)
        } detail: {
            ZStack {
                Color.vBgRaised.ignoresSafeArea()
                switch selection {
                case .chat(let id): ChatView(contactId: id)
                case .profile: ProfileView()
                case .relays: RelaysView()
                case nil: WelcomeView()
                }
            }
        }
        .toolbar {
            Button { showAddContact = true } label: {
                Label("Добавить контакт", systemImage: "person.crop.circle.badge.plus")
            }
        }
        .sheet(isPresented: $showAddContact) { AddContactSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .veilShowAddContact)) { _ in
            showAddContact = true
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                if let me = store.selfContact {
                    ChatRow(contact: me, isSelfChat: true)
                        .tag(SidebarSelection.chat(me.signPub))
                }
                ForEach(sortedContacts) { contact in
                    ChatRow(contact: contact)
                        .tag(SidebarSelection.chat(contact.signPub))
                }
            }
            Section {
                Label {
                    Text("Мой профиль").foregroundStyle(Color.vMuted)
                } icon: {
                    Image(systemName: "person.crop.circle").foregroundStyle(Color.vMuted)
                }
                .tag(SidebarSelection.profile)
                Label {
                    Text("Реле-серверы").foregroundStyle(Color.vMuted)
                } icon: {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Color.vMuted)
                }
                .tag(SidebarSelection.relays)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.vBg)
        .environment(\.defaultMinListRowHeight, 48)
    }
}


struct ChatRow: View {
    @EnvironmentObject var store: AppStore
    let contact: Contact
    var isSelfChat = false

    var body: some View {
        HStack(spacing: 11) {
            VeilAvatar(name: isSelfChat ? "★" : contact.name,
                       isSelf: isSelfChat,
                       online: !isSelfChat,
                       size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(isSelfChat ? "Избранное" : contact.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.vText)
                    .lineLimit(1)
                if let last = store.lastMessage(for: contact.signPub) {
                    Text(last.incoming ? last.text : "Вы: \(last.text)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.vMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

struct WelcomeView: View {
    var body: some View {
        ZStack {
            Color.vBgRaised.ignoresSafeArea()
            RadialGradient(colors: [Color.vAccent.opacity(0.13), .clear],
                           center: .center, startRadius: 0, endRadius: 260)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                VeilLogo(size: 68)
                    .shadow(color: Color.vAccent.opacity(0.4), radius: 24, y: 10)
                Text("Veil").font(.system(size: 24, weight: .bold))
                Text("Выберите чат слева или добавьте контакт")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vMuted)
            }
        }
    }
}

// MARK: - Чат

struct ChatView: View {
    @EnvironmentObject var store: AppStore
    let contactId: String
    @State private var input = ""
    @State private var replyTarget: StoredMessage?
    @State private var editingMsg: StoredMessage?
    @State private var forwardMsg: StoredMessage?
    @State private var showForwardSheet = false

    private var contact: Contact? { store.contact(contactId) }
    private var isSelf: Bool { contactId == store.mySignPub }
    private var messages: [StoredMessage] { store.messages(for: contactId) }

    var body: some View {
        VStack(spacing: 0) {
            if let contact {
                header(contact)
                Divider().overlay(Color.vHairline)
                if let error = store.lastError {
                    errorBanner(error)
                    Divider().overlay(Color.vHairline)
                }
                messageList
                Divider().overlay(Color.vHairline)
                inputBar
            } else {
                WelcomeView()
            }
        }
        .sheet(isPresented: $showForwardSheet) {
            ForwardContactSheet(message: forwardMsg)
        }
        .navigationTitle(contact.map { $0.signPub == store.mySignPub ? "Избранное" : $0.name } ?? "")
    }

    // MARK: Шапка

    private func header(_ contact: Contact) -> some View {
        HStack(spacing: 12) {
            VeilAvatar(name: contact.name, isSelf: isSelf, online: !isSelf, size: 40)
            Text(isSelf ? "Избранное" : contact.name)
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Button { copyID(contact) } label: {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.vMuted)
                    .frame(width: 32, height: 32)
                    .background(Color.vField)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Скопировать ID")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.vBgRaised)
    }

    private func copyID(_ c: Contact) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.signPub, forType: .string)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(error).font(.system(size: 13))
            Spacer()
            Button { store.lastError = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.vText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color.vAccent.opacity(0.16))
        .foregroundStyle(Color.vAccent)
    }

    // MARK: Лента сообщений

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                            .contextMenu { messageMenu(msg) }
                    }
                }
                .padding(16)
                .animation(.spring(response: 0.38, dampingFraction: 0.82), value: messages.count)
            }
            .background(Color.vBg)
            .onChange(of: messages.count) { _ in scrollToLast(proxy) }
            .onAppear { scrollToLast(proxy) }
        }
    }

    @ViewBuilder
    private func messageMenu(_ msg: StoredMessage) -> some View {
        Button(action: { startReply(msg) }) {
            Label("Ответить", systemImage: "arrowshape.turn.up.left.fill")
        }
        if !msg.incoming {
            Button(action: { startEdit(msg) }) {
                Label("Редактировать", systemImage: "pencil")
            }
        }
        Button(action: { forwardMsg = msg; showForwardSheet = true }) {
            Label("Переслать", systemImage: "arrow.right.square.fill")
        }
        Divider()
        Button(role: .destructive, action: { store.deleteMessage(msg) }) {
            Label("Удалить", systemImage: "trash")
        }
    }

    private func startReply(_ msg: StoredMessage) {
        editingMsg = nil
        replyTarget = msg
        input = ""
    }
    private func startEdit(_ msg: StoredMessage) {
        replyTarget = nil
        editingMsg = msg
        input = msg.text
    }
    private func cancelComposeBanner() {
        replyTarget = nil
        editingMsg = nil
    }

    private func scrollToLast(_ proxy: ScrollViewProxy) {
        if let last = messages.last {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    // MARK: Поле ввода

    private var inputBar: some View {
        VStack(spacing: 8) {
            if let replyTarget {
                composeBanner(kind: .reply(replyTarget.text))
            } else if let editingMsg {
                composeBanner(kind: .edit)
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField(editingMsg != nil ? "Изменить сообщение…" : "Сообщение…", text: $input)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.vText)
                        .onSubmit(send)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Color.vField)
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1))
                .clipShape(Capsule())

                Button(action: send) {
                    Image(systemName: editingMsg != nil ? "pencil" : "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(VeilGradient.brand)
                        .clipShape(Circle())
                        .shadow(color: Color.vAccent.opacity(0.4), radius: 9, y: 4)
                        .scaleEffect(input.isEmpty ? 1 : 1.06)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: input.isEmpty == false)
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.vBgRaised)
    }

    private enum ComposeKind {
        case reply(String)
        case edit
    }

    private func composeBanner(kind: ComposeKind) -> some View {
        HStack(spacing: 8) {
            switch kind {
            case .reply(let text):
                Image(systemName: "arrowshape.turn.up.left.fill").foregroundStyle(Color.vAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ответить").font(.caption2).foregroundStyle(Color.vAccent).fontWeight(.semibold)
                    Text(String(text.prefix(70))).font(.caption).foregroundStyle(Color.vMuted).lineLimit(1)
                }
            case .edit:
                Image(systemName: "pencil").foregroundStyle(Color.vAccent)
                Text("Редактирование").font(.caption).foregroundStyle(Color.vAccent).fontWeight(.semibold)
            }
            Spacer()
            Button { cancelComposeBanner() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.vMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.vAccent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func send() {
        let text = input
        if let em = editingMsg {
            store.editMessage(em, to: text)
        } else {
            store.sendReply(text, to: contactId, replyTo: replyTarget)
        }
        input = ""
        cancelComposeBanner()
    }
}

// MARK: - Пузырь сообщения

struct MessageBubble: View {
    let message: StoredMessage

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var timeText: String {
        Self.timeFormatter.string(from: Date(timeIntervalSince1970: message.ts / 1000))
    }
    private var isIncoming: Bool { message.incoming }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if !isIncoming { Spacer(minLength: 64) }
            VStack(alignment: isIncoming ? .leading : .trailing, spacing: 4) {
                bubbleContent
                footer
            }
            if isIncoming { Spacer(minLength: 64) }
        }
        .transition(.asymmetric(
            insertion: .move(edge: isIncoming ? .leading : .trailing)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 0.94)),
            removal: .opacity))
    }

    private var bubbleContent: some View {
        VStack(alignment: isIncoming ? .leading : .trailing, spacing: 6) {
            if let r = message.replyTo, !r.isEmpty {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isIncoming ? Color.white.opacity(0.25) : .white.opacity(0.55))
                        .frame(width: 3)
                    Text(String(r.prefix(80)))
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(isIncoming ? Color.vMuted : Color.white.opacity(0.85))
                    Spacer(minLength: 0)
                }
                .padding(7)
                .background(Color.white.opacity(isIncoming ? 0.04 : 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(message.text)
                .textSelection(.enabled)
                .font(.system(size: 15))
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: isIncoming ? .leading : .trailing)
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(isIncoming ? AnyShapeStyle(Color.vBubbleIn) : AnyShapeStyle(VeilGradient.brand))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: isIncoming ? .clear : Color.vAccent.opacity(0.25), radius: 8, y: 4)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if isIncoming { Spacer(minLength: 0) }
            if message.edited == true {
                Text("изменено").font(.system(size: 10)).italic()
                    .foregroundStyle(isIncoming ? Color.vMuted : Color.white.opacity(0.7))
            }
            Text(timeText)
                .font(.system(size: 10))
                .foregroundStyle(isIncoming ? Color.vMuted : Color.white.opacity(0.8))
            if !isIncoming {
                Text(message.delivered ? "✓✓" : "✓…")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isIncoming ? Color.vMuted : Color.white.opacity(0.9))
            }
            if !isIncoming { Spacer(minLength: 0) }
        }
    }
}

// MARK: - Пересылка (выбор чата)

struct ForwardContactSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let message: StoredMessage?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.square.fill").foregroundStyle(Color.vAccent)
                Text("Переслать в чат").font(.headline)
                Spacer()
            }
            if let text = message?.text {
                Text(String(text.prefix(80)))
                    .font(.caption).foregroundStyle(Color.vMuted).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Color.vHairline)
            ScrollView {
                VStack(spacing: 4) {
                    if let me = store.selfContact {
                        forwardRow(me, isSelf: true)
                    }
                    ForEach(store.contacts) { c in
                        forwardRow(c)
                    }
                    if store.contacts.isEmpty {
                        Text("Нет чатов для пересылки").font(.caption).foregroundStyle(Color.vMuted)
                            .padding(.vertical, 20)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 260)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .background(Color.vPanel)
    }

    private func forwardRow(_ contact: Contact, isSelf: Bool = false) -> some View {
        Button {
            if let msg = message {
                store.forwardMessage(msg, to: contact.signPub)
            }
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VeilAvatar(name: isSelf ? "★" : contact.name, isSelf: isSelf, size: 34)
                Text(isSelf ? "Избранное" : contact.name)
                    .font(.system(size: 14)).foregroundStyle(Color.vText)
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption).foregroundStyle(Color.vMuted)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
