import Foundation
import UserNotifications

enum Notifier {
    static let catCall = "CALL_INCOMING"
    static let catSms = "SMS_IN"
    static let catMissed = "CALL_MISSED"
    static let actAnswer = "ANSWER"
    static let actAnswerSpeaker = "ANSWER_SPEAKER"
    static let actReject = "REJECT"
    static let actReply = "REPLY"
    static let actCallback = "CALLBACK"
    static let incomingCallId = "call.incoming"

    private static let center = UNUserNotificationCenter.current()

    static func setup() {
        let answer = UNNotificationAction(identifier: actAnswer, title: "پاسخ", options: [])
        let answerSpk = UNNotificationAction(identifier: actAnswerSpeaker, title: "پاسخ با بلندگو", options: [])
        let reject = UNNotificationAction(identifier: actReject, title: "رد تماس", options: [.destructive])
        let reply = UNTextInputNotificationAction(identifier: actReply, title: "پاسخ", options: [],
                                                  textInputButtonTitle: "ارسال", textInputPlaceholder: "پیام…")
        let callback = UNNotificationAction(identifier: actCallback, title: "تماس", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: catCall, actions: [answer, answerSpk, reject], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: catSms, actions: [reply], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: catMissed, actions: [callback], intentIdentifiers: [], options: []),
        ])
    }

    static func requestAuthorization(_ done: ((Bool) -> Void)? = nil) {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            DispatchQueue.main.async { done?(ok) }
        }
    }

    static func authorizationStatus(_ done: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { s in DispatchQueue.main.async { done(s.authorizationStatus) } }
    }

    static func postSms(_ m: SmsMessage, simLabel: String? = nil) {
        let c = UNMutableNotificationContent()
        c.title = m.name.isEmpty ? Phone.ltr(m.address) : m.name
        c.body = m.body
        c.sound = .default
        c.categoryIdentifier = catSms
        if let simLabel { c.subtitle = simLabel }
        c.threadIdentifier = "sms." + Phone.key(m.address)
        c.userInfo = ["kind": "sms", "address": m.address, "subId": m.subId ?? -1]
        add("sms.\(m.address).\(m.date)", c)
    }

    static func postIncomingCall(_ call: CallInfo, simLabel: String? = nil) {
        let c = UNMutableNotificationContent()
        c.title = "تماس ورودی"
        c.body = call.name.isEmpty ? Phone.ltr(call.number.isEmpty ? "شماره نامشخص" : call.number) : "\(call.name)  \(Phone.ltr(call.number))"
        c.sound = .default
        c.categoryIdentifier = catCall
        if let simLabel { c.subtitle = simLabel }
        c.userInfo = ["kind": "call", "number": call.number]
        if #available(iOS 15.0, *) { c.interruptionLevel = .timeSensitive }
        add(incomingCallId, c)
    }

    static func removeIncomingCall() {
        center.removeDeliveredNotifications(withIdentifiers: [incomingCallId])
        center.removePendingNotificationRequests(withIdentifiers: [incomingCallId])
    }

    static func postMissed(number: String, name: String) {
        let c = UNMutableNotificationContent()
        c.title = "تماس از دست رفته"
        c.body = name.isEmpty ? Phone.ltr(number.isEmpty ? "شماره نامشخص" : number) : name
        c.sound = .default
        c.categoryIdentifier = catMissed
        c.userInfo = ["kind": "missed", "number": number]
        add("missed.\(number).\(Date().timeIntervalSince1970)", c)
    }

    static func postInfo(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        add("info.\(Date().timeIntervalSince1970)", c)
    }

    private static func add(_ id: String, _ content: UNNotificationContent) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - De-duplication of SMS notifications across live events and background syncs

    private static let lastKey = "sms.lastNotified"
    private static let recentKey = "sms.recentNotified"

    private struct Seen: Codable { var address: String; var body: String; var date: Int64 }

    private static var recent: [Seen] = {
        guard let d = UserDefaults.standard.data(forKey: recentKey) else { return [] }
        return (try? JSONDecoder().decode([Seen].self, from: d)) ?? []
    }() {
        didSet { if let d = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(d, forKey: recentKey) } }
    }

    static var lastMissedDate: Int64 {
        get { Int64(UserDefaults.standard.double(forKey: "missed.lastNotified")) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "missed.lastNotified") }
    }

    static var lastSmsDate: Int64 {
        get { Int64(UserDefaults.standard.double(forKey: lastKey)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: lastKey) }
    }

    /// Returns true if this message has not been notified yet (and records it).
    static func shouldNotify(_ m: SmsMessage) -> Bool {
        let cutoff = m.date - 10 * 60 * 1000
        recent.removeAll { $0.date < cutoff }
        let dup = recent.contains { $0.body == m.body && Phone.same($0.address, m.address) && abs($0.date - m.date) < 120_000 }
        if dup { return false }
        if m.date <= lastSmsDate - 120_000 { return false }
        recent.append(Seen(address: m.address, body: m.body, date: m.date))
        lastSmsDate = max(lastSmsDate, m.date)
        return true
    }
}
