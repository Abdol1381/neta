import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        AppModel.shared.launch()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let kind = notification.request.content.userInfo["kind"] as? String
        // The in-app call screen is already visible for calls; just play the sound.
        completionHandler(kind == "call" ? [.sound, .list] : [.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            AppModel.shared.handleNotificationAction(action, userInfo: info, text: text, completion: completionHandler)
        }
    }
}

@main
struct SIMBridgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environment(\.layoutDirection, .leftToRight)
                .environment(\.locale, Locale(identifier: "en_US"))
                .onChange(of: phase) { p in
                    switch p {
                    case .active: model.enterForeground()
                    case .background: model.enterBackground()
                    default: break
                    }
                }
        }
    }
}
