// Проверочная точка входа для macOS: компилирует И проверяет UI-файл iOS
// (ViewsIOS.swift) на macOS — тот же кросс-платформенный SwiftUI-код.
// Используется ios/build_check.sh; в само iOS-приложение не входит.
import SwiftUI

final class CheckAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingView(rootView: RootViewIOS()
            .environmentObject(AppStore.shared))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window?.title = "Veil iOS UI — build check"
        window?.contentView = hosting
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // авто-закрытие: окно живёт 6 секунд, затем проверка завершается успехом
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            print("IOS-CHECK-OK")
            exit(0)
        }
    }
}

let app = NSApplication.shared
let delegate = CheckAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
