import Foundation

/// Launch arguments used only by the automated UI test on the iOS Simulator (Debug builds).
/// In Release builds every hook is off.
enum TestHooks {
    #if DEBUG
    private static let d = UserDefaults.standard
    static var isActive: Bool { d.bool(forKey: "SIMBridgeTestMode") }
    static var reset: Bool { d.bool(forKey: "SIMBridgeReset") }
    static var pairPayload: String? { d.string(forKey: "SIMBridgeTestPair") }
    static var openFirstThread: Bool { d.string(forKey: "SIMBridgeTab") == "thread" }
    static var initialTab: AppTab? {
        switch d.string(forKey: "SIMBridgeTab") {
        case "messages", "thread": return .messages
        case "phone": return .phone
        case "recents": return .phone
        case "contacts": return .contacts
        case "settings": return .settings
        case "home": return .home
        default: return nil
        }
    }
    static var phoneSegment: Int { d.string(forKey: "SIMBridgeTab") == "recents" ? 1 : 0 }
    #else
    static let isActive = false
    static let openFirstThread = false
    static let phoneSegment = 0
    #endif
}
