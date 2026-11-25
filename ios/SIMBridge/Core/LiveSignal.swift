import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Shows the Android SIM's signal bars on the Lock Screen and in the Dynamic Island (Live Activity).
/// The bars in the iPhone's own status bar belong to its modem and no app can change them.
final class LiveSignal {
    private var lastPush = Date.distantPast
    private var lastFailure = Date.distantPast

    /// Called every 2 s by the app's watchdog and when the app comes to the foreground.
    func sync(status: PhoneStatus?, linked: Bool, enabled: Bool, foreground: Bool) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *), !TestHooks.isActive else { return }
        let all = Activity<SignalAttributes>.activities
        guard enabled, let status, ActivityAuthorizationInfo().areActivitiesEnabled else {
            if !all.isEmpty { endAll(all) }
            return
        }
        let state = Self.state(from: status, linked: linked)
        let active = all.filter { $0.activityState == .active }
        if let a = active.first {
            if active.count > 1 { endAll(Array(active.dropFirst())) }
            // Push on change, and at least once a minute so the activity is not marked stale.
            guard a.content.state != state || Date().timeIntervalSince(lastPush) > 60 else { return }
            lastPush = Date()
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(180))
            Task { await a.update(content) }
        } else {
            // iOS lets an app start a Live Activity only while it is on screen.
            guard foreground, Date().timeIntervalSince(lastFailure) > 30 else { return }
            do {
                _ = try Activity.request(attributes: SignalAttributes(device: status.device.model),
                                         content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(180)),
                                         pushType: nil)
                lastPush = Date()
                dlog("signal live activity started")
            } catch {
                lastFailure = Date()
                dlog("signal live activity: \(error)")
            }
        }
        #endif
    }

    func stop() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        let all = Activity<SignalAttributes>.activities
        if !all.isEmpty { endAll(all) }
        #endif
    }

    #if canImport(ActivityKit)
    @available(iOS 16.2, *)
    private func endAll(_ list: [Activity<SignalAttributes>]) {
        for a in list { Task { await a.end(nil, dismissalPolicy: .immediate) } }
    }

    @available(iOS 16.2, *)
    private static func state(from s: PhoneStatus, linked: Bool) -> SignalAttributes.ContentState {
        let sims = s.sims.sorted { $0.slot < $1.slot }
        let main = sims.first(where: { $0.voiceSim }) ?? sims.first
        let other = sims.first(where: { $0.subId != main?.subId })
        return .init(carrier: main?.title ?? "",
                     level: main?.level ?? 0,
                     gen: main?.gen ?? "",
                     service: s.airplane ? "off" : (main?.service ?? "out"),
                     linked: linked,
                     second: other.map { $0.inService ? $0.level : 0 },
                     battery: s.battery.level)
    }
    #endif
}
