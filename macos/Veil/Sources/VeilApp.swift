import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
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
                .preferredColorScheme(.dark)
                .frame(minWidth: 940, minHeight: 640)
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