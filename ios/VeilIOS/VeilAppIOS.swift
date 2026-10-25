import SwiftUI

// Точка входа iOS-приложения (файл не участвует в кросс-проверке на macOS).

final class AppDelegateIOS: NSObject, UIApplicationDelegate {
    func applicationDidFinishLaunching(_ application: UIApplication) {
        AppStore.shared.bootstrap()
        RelayService.shared.attach(store: AppStore.shared)
    }
}

@main
struct VeilIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegateIOS.self) var appDelegate
    @StateObject private var store = AppStore.shared

    var body: some Scene {
        WindowGroup {
            RootViewIOS()
                .environmentObject(store)
        }
    }
}
