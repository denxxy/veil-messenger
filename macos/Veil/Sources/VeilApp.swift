import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppStore.shared.bootstrap()
        RelayService.shared.attach(store: AppStore.shared)
    }
}

struct VeilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = AppStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 880, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Добавить контакт…") {
                    NotificationCenter.default.post(name: .veilShowAddContact, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let veilShowAddContact = Notification.Name("veilShowAddContact")
}
