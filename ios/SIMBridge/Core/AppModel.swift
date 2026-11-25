import Foundation
import SwiftUI
import UIKit
import UserNotifications

enum PairingStage: Equatable {
    case idle
    case connecting
    case confirm(code: String)
    case success
    case failed(String)
}

/// Tabs, laid out like the iPhone's Messages + Phone apps.
enum AppTab: Hashable { case messages, calls, contacts, keypad, settings }

/// Single source of truth for the UI. All mutations happen on the main thread.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var pairing: Pairing?
    @Published private(set) var conn: ConnState = .idle
    @Published private(set) var status: PhoneStatus?
    @Published private(set) var call: CallInfo = .idle
    @Published var speakerOn = false
    @Published var muted = false
    @Published private(set) var threads: [SmsThread] = []
    @Published private(set) var messages: [Int64: [SmsMessage]] = [:]
    /// iPhone + Android contacts, merged and de-duplicated by number.
    @Published private(set) var contacts: [Contact] = []
    private var androidContacts: [Contact] = []
    /// Phone.key -> name from the Android phone's contacts.
    private var androidByKey: [String: String] = [:]
    let iphoneContacts = IPhoneContacts()
    @Published private(set) var recents: [CallLogEntry] = []
    @Published private(set) var latencyMs: Int?
    @Published private(set) var bleConnected = false
    @Published private(set) var loadingThreads = false
    @Published var pairingStage: PairingStage = .idle
    @Published var toast: String?
    @Published var tab: AppTab = .messages
    /// Missed calls newer than this (ms) count toward the Calls tab badge, like the Phone app.
    @Published private(set) var missedSeenAt: Int64 = Int64(UserDefaults.standard.double(forKey: "missedSeenAt"))

    func markMissedSeen() {
        let latest = recents.first?.date ?? Int64(Date().timeIntervalSince1970 * 1000)
        guard latest > missedSeenAt else { return }
        missedSeenAt = latest
        UserDefaults.standard.set(Double(latest), forKey: "missedSeenAt")
    }
    @Published var callScreenMinimized = false
    /// Call downlink audio is playing on the iPhone (developer mode on Android).
    @Published private(set) var listening = false
    /// Call audio on the iPhone's loudspeaker instead of the earpiece (only while listening).
    @Published private(set) var iphoneSpeaker = false

    func toggleIphoneSpeaker() {
        iphoneSpeaker.toggle()
        audioPlayer.setSpeaker(iphoneSpeaker)
        updateProximity()
    }

    /// Screen off when the iPhone is held to the ear, like a phone call (earpiece only).
    private func updateProximity() {
        let want = call.state == "offhook" && listening && !iphoneSpeaker && isForeground
        if UIDevice.current.isProximityMonitoringEnabled != want {
            UIDevice.current.isProximityMonitoringEnabled = want
        }
    }
    let audioPlayer = CallAudioPlayer()
    let callKit = CallKitManager()
    let keeper = BackgroundKeeper()
    let liveSignal = LiveSignal()
    /// The Android SIM's signal bars on the Lock Screen and in the Dynamic Island.
    @Published var signalActivity: Bool = UserDefaults.standard.object(forKey: "signalActivity") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(signalActivity, forKey: "signalActivity")
            syncLiveSignal()
        }
    }

    private func syncLiveSignal() {
        liveSignal.sync(status: pairing == nil ? nil : status, linked: conn.isReady, enabled: signalActivity,
                        foreground: isForeground)
    }
    /// Internet phone line (SIP). Forwarded SIM calls ring here with two-way audio on the iPhone.
    let sip = SipPhone()
    @Published private(set) var sipState = "off"          // off / registering / ok / failed
    @Published private(set) var sipMessage = ""
    @Published private(set) var sipAccount: SipAccount? = SipAccountStore.load()
    /// subId (string) -> forwarding mode set from this iPhone ("off", "all", "conditional")
    @Published private(set) var forwarding: [String: String] = {
        (UserDefaults.standard.dictionary(forKey: "forwarding") as? [String: String]) ?? [:]
    }()
    /// Stay connected in the background (inaudible audio loop) so calls/SMS arrive instantly.
    @Published var keepConnected: Bool = UserDefaults.standard.object(forKey: "keepConnected") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepConnected, forKey: "keepConnected")
            if keepConnected { startKeeperIfIdle() } else { keeper.stop() }
        }
    }
    private var keeping: Bool { keepConnected && pairing != nil && keeper.isRunning }

    /// Back to the inaudible loop after call audio / a CallKit call released the audio session.
    private func resumeKeeper() {
        guard keepConnected, pairing != nil || sipAccount?.isComplete == true, call.isIdle, !listening, !callKit.hasCall,
              !sip.hasCall, !TestHooks.isActive else { return }
        // In the background the app has only seconds before iOS suspends it once audio stopped:
        // hold a background task while the silent loop takes over again.
        if !isForeground { beginBackgroundTask(seconds: 20) }
        keeper.resume()
        for delay in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.keepConnected, !self.keeper.isRunning, self.keeper.mayTouchSession() else { return }
                dlog("keeper: retry after call audio")
                self.keeper.start()
            }
        }
    }

    /// Starts the background keeper unless a call's audio session is in use.
    private func startKeeperIfIdle() {
        guard keepConnected, pairing != nil || sipAccount?.isComplete == true, !TestHooks.isActive, !listening,
              !callKit.hasCall, !sip.hasCall else { return }
        keeper.start()
    }
    /// Ring with the iPhone's own call screen (CallKit).
    @Published var useCallKit: Bool = UserDefaults.standard.object(forKey: "useCallKit") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useCallKit, forKey: "useCallKit") }
    }
    var canListen: Bool { status?.devAudio == "ready" }
    @Published var openThreadId: Int64?

    let client = BridgeClient()
    let ble = BLEWaker()

    private(set) var isForeground = true
    private var pingTimer: Timer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var bgDeadline: DispatchWorkItem?
    private var threadsRefreshWork: DispatchWorkItem?
    /// ref -> local message id, for optimistic outgoing SMS.
    private var outgoing: [String: (threadId: Int64?, localId: String, address: String)] = [:]
    private var contactsLoaded = false
    /// threadId -> date (ms) up to which the user has read that conversation on the iPhone.
    private var readMarks: [String: Int64] = {
        (UserDefaults.standard.dictionary(forKey: "sms.readMarks") as? [String: NSNumber])?
            .mapValues { $0.int64Value } ?? [:]
    }() {
        didSet { UserDefaults.standard.set(readMarks.mapValues { NSNumber(value: $0) }, forKey: "sms.readMarks") }
    }

    private init() {
        pairing = PairingStore.load()
        client.onState = { [weak self] s in self?.connStateChanged(s) }
        client.onReady = { [weak self] hosts, port in self?.didBecomeReady(hosts: hosts, port: port) }
        client.onEvent = { [weak self] t, body in self?.handleEvent(t, body) }
        client.onPaired = { [weak self] p in self?.didPair(p) }
        client.onRejected = { [weak self] code in self?.rejected(code) }
        ble.onWake = { [weak self] in self?.handleWake() }
        ble.onConnectedChange = { [weak self] c in self?.bleConnected = c }
        iphoneContacts.onChange = { [weak self] in self?.contactsChanged() }
        setupCallKit()
        startWatchdog()
        keeper.mayTouchSession = { [weak self] in
            guard let self else { return true }
            return self.call.isIdle && !self.listening && !self.callKit.hasCall && !self.sip.hasCall && !self.audioPlayer.running
        }
        sip.onChange = { [weak self] in
            guard let self else { return }
            self.sipState = self.sip.registration
            self.sipMessage = self.sip.registrationMessage
        }
        sip.onCallActiveChanged = { [weak self] active in
            guard let self else { return }
            // The silent loop keeps running during the call (mixable); afterwards restore its session.
            if !active { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.resumeKeeper() } }
        }
    }

    // MARK: - Internet phone line (SIP) + operator call forwarding

    func saveSipAccount(_ acc: SipAccount?) {
        SipAccountStore.save(acc)
        sipAccount = acc
        sip.configure(acc)
    }

    /// Asks the Android phone to set the operator's call forwarding for a SIM to the VoIP line.
    /// mode: "all" (every call rings on the iPhone), "conditional" (only when the Android phone does
    /// not answer / is busy / unreachable) or "off".
    func setForwarding(subId: Int?, mode: String, _ done: ((Bool) -> Void)? = nil) {
        let number = sipAccount?.lineNumber ?? ""
        if mode != "off" && number.filter(\.isNumber).count < 5 {
            toast = "Enter the internet line's phone number first"
            done?(false)
            return
        }
        var params: [String: Any] = ["mode": mode, "number": number]
        if let subId { params["subId"] = subId }
        client.request("forward", params) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success:
                self.forwarding[String(subId ?? -1)] = mode
                UserDefaults.standard.set(self.forwarding, forKey: "forwarding")
                self.toast = mode == "off" ? "Call forwarding turned off (the carrier confirms on the Android phone)"
                                           : "Call forwarding requested (the carrier confirms on the Android phone)"
                done?(true)
            case .failure(let e):
                self.report(e)
                done?(false)
            }
        }
    }

    /// Outgoing call through the internet line.
    func dialVoip(_ number: String) {
        if !sip.startCall(number) { toast = "Internet line not connected" }
    }

    private func setupCallKit() {
        callKit.onAnswer = { [weak self] done in
            guard let self else { done(false); return }
            self.client.ensureReady(timeout: 10) { ok in
                guard ok else { done(false); return }
                self.answer(speaker: false) { done($0) }
            }
        }
        callKit.onEnd = { [weak self] done in
            guard let self, !self.call.isIdle else { done(true); return }
            self.client.ensureReady(timeout: 10) { _ in self.endCall { done($0) } }
        }
        callKit.onMute = { [weak self] muted in self?.setMute(muted) }
        // While a native call is up, keep the audio engine running: it plays the call audio when
        // listening and keeps the app alive in the background so the call state stays in sync.
        callKit.onAudioActivated = { [weak self] in self?.audioPlayer.start(managedByCallKit: true) }
        callKit.onAudioDeactivated = { [weak self] in
            guard let self else { return }
            self.audioPlayer.stop()
            if self.listening && self.call.state == "offhook" {
                self.audioPlayer.start()
                self.audioPlayer.setSpeaker(self.iphoneSpeaker)
            } else { self.resumeKeeper() }
        }
    }

    // MARK: - Lifecycle

    func launch() {
        Notifier.setup()
        iphoneContacts.reload()
        if !TestHooks.isActive { sip.configure(sipAccount) }
        // iOS may relaunch the app in the background (Bluetooth state restoration). In that case stay
        // quiet: the BLE wake handler opens the connection only for as long as it is needed.
        isForeground = UIApplication.shared.applicationState != .background
        client.autoReconnect = isForeground
        #if DEBUG
        if TestHooks.reset { PairingStore.delete(); pairing = nil; Notifier.lastSmsDate = 0; Notifier.lastMissedDate = 0 }
        if let tab = TestHooks.initialTab { self.tab = tab }
        #endif
        if let p = pairing {
            if isForeground {
                client.connect(.device(p))
                startKeeperIfIdle()
            }
            if !TestHooks.isActive { ble.start(serverId: p.serverId) }
        }
        #if DEBUG
        if pairing == nil, let payload = TestHooks.pairPayload {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in _ = self?.startPairing(with: payload) }
        }
        #endif
    }

    func enterForeground() {
        isForeground = true
        sip.refreshRegistration()
        startKeeperIfIdle()
        client.autoReconnect = true
        endBackgroundTask()
        if let p = pairing {
            if client.mode == nil { client.connect(.device(p)) } else { client.kick() }
            startPing()
            if conn.isReady { refreshAll() }
        }
        UIApplication.shared.applicationIconBadgeNumber = 0
        syncLiveSignal()
    }

    func enterBackground() {
        isForeground = false
        if keepConnected && (pairing != nil || sipAccount?.isComplete == true) {
            // Always-connected mode: keep the link (and pings) running in the background. If the
            // silent loop is not playing right now, the watchdog restarts it.
            if !keeper.isRunning { startKeeperIfIdle() }
            dlog("background: staying connected (keeper \(keeper.isRunning ? "on" : "off"))")
            return
        }
        stopPing()
        client.autoReconnect = false
        // Finish in-flight work, then release the socket; BLE will wake us for new events.
        beginBackgroundTask(seconds: 8)
    }

    // MARK: - Pairing

    func startPairing(with payload: String) -> Bool {
        guard let offer = PairOffer(string: payload) else { return false }
        pairingStage = .connecting
        client.reset()
        client.autoReconnect = false
        client.connect(.pair(offer))
        return true
    }

    func cancelPairing() {
        if pairing == nil { client.reset() }
        pairingStage = .idle
    }

    private func didPair(_ p: Pairing) {
        PairingStore.save(p)
        pairing = p
        pairingStage = .success
        Notifier.lastSmsDate = 0
        Notifier.lastMissedDate = 0
        readMarks = [:]
        client.reset()
        client.autoReconnect = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, let p = self.pairing else { return }
            self.client.connect(.device(p))
            self.startKeeperIfIdle()
            if !TestHooks.isActive {
                self.ble.start(serverId: p.serverId)
                Notifier.requestAuthorization()
                if self.iphoneContacts.status == .notDetermined { self.iphoneContacts.requestAccess() }
            }
        }
    }

    private func rejected(_ code: String) {
        switch code {
        case "denied":
            pairingStage = .failed("The request was declined on the Android phone.")
            client.reset()
        case "pairing_closed":
            pairingStage = .failed("This QR code has expired. Tap “Connect iPhone” again in the Android app and scan the new code.")
            client.reset()
        case "unknown_device":
            if pairing != nil {
                toast = "This iPhone was removed on the Android phone. Please pair again."
                unpair()
            } else {
                pairingStage = .failed("The connection was not accepted.")
            }
        default:
            break
        }
    }

    func unpair() {
        keeper.stop()
        liveSignal.stop()
        client.reset()
        ble.stop()
        PairingStore.delete()
        pairing = nil
        status = nil
        call = .idle
        threads = []
        messages = [:]
        contacts = iphoneContacts.list
        androidContacts = []
        androidByKey = [:]
        recents = []
        contactsLoaded = false
        pairingStage = .idle
        readMarks = [:]
        Notifier.lastSmsDate = 0
        Notifier.lastMissedDate = 0
    }

    // MARK: - Connection

    private func connStateChanged(_ s: ConnState) {
        dlog("link: \(s)")
        conn = s
        if case .awaitingApproval(let code) = s, pairing == nil { pairingStage = .confirm(code: code) }
        if case .failed(let reason) = s, pairing == nil {
            switch pairingStage {
            case .connecting, .confirm: pairingStage = .failed(reason)
            default: break
            }
        }
        if !s.isReady { latencyMs = nil }
    }

    private func didBecomeReady(hosts: [String], port: Int?) {
        // Remember the phone's current addresses for next time.
        if var p = pairing {
            var changed = false
            if !hosts.isEmpty {
                let merged = Array((hosts + p.hosts).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(8))
                if merged != p.hosts { p.hosts = merged; changed = true }
            }
            if let port, port != p.port { p.port = port; changed = true }
            if changed { pairing = p; PairingStore.save(p) }
        }
        sync()
        if isForeground {
            startPing()
            refreshAll()
        }
    }

    func reconnect() { client.kick() }

    private func startPing() {
        guard pingTimer == nil else { return }
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.ping() }
        ping()
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private var missedPings = 0

    private func ping() {
        guard conn.isReady else { return }
        let start = Date()
        client.request("ping", ["ts": Int64(start.timeIntervalSince1970 * 1000)], timeout: 6) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success:
                self.missedPings = 0
                self.latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            case .failure:
                self.missedPings += 1
                if self.missedPings >= 2 { self.missedPings = 0; self.client.disconnect(); self.client.kick() }
            }
        }
    }

    // MARK: - Background wake (BLE doorbell)

    private func handleWake() {
        guard pairing != nil, !isForeground else { return }
        beginBackgroundTask(seconds: 25)
        dlog("bluetooth wake")
        if keepConnected && !keeper.isRunning { startKeeperIfIdle() }
        client.autoReconnect = true
        client.ensureReady(timeout: 15) { [weak self] ok in
            guard let self else { return }
            if !ok { self.endBackgroundTask() }
            // On success didBecomeReady() already ran sync(); the task ends on its deadline.
        }
        if conn.isReady { sync() }
    }

    private func beginBackgroundTask(seconds: TimeInterval) {
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "simbridge.sync") { [weak self] in
                self?.endBackgroundTask()
            }
        }
        bgDeadline?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.endBackgroundTask() }
        bgDeadline = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func endBackgroundTask() {
        bgDeadline?.cancel()
        bgDeadline = nil
        // While call audio is playing the app stays alive (audio background mode) and keeps the link.
        if !isForeground && !listening && !callKit.hasCall && !(keepConnected && pairing != nil) {
            client.autoReconnect = false
            client.disconnect()
        }
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    // MARK: - Sync & events

    func sync() {
        var params: [String: Any] = [:]
        let after = Notifier.lastSmsDate
        if after > 0 { params["smsAfter"] = after }
        let missedAfter = Notifier.lastMissedDate
        if missedAfter > 0 { params["missedAfter"] = missedAfter }
        client.request("sync", params) { [weak self] r in
            guard let self, case .success(let d) = r else { return }
            if let s = JSONBridge.decode(PhoneStatus.self, d["status"]) { self.status = s }
            if let c = JSONBridge.decode(CallInfo.self, d["call"]) { self.apply(call: c) }
            if let a = d["audio"] as? [String: Any] {
                self.speakerOn = a["speaker"] as? Bool ?? false
                self.muted = a["muted"] as? Bool ?? false
            }
            let serverTime = (d["time"] as? NSNumber)?.int64Value ?? 0
            if after == 0, serverTime > 0 { Notifier.lastSmsDate = serverTime }
            if missedAfter == 0, serverTime > 0 { Notifier.lastMissedDate = serverTime }
            if let missed = JSONBridge.decode([CallLogEntry].self, d["missed"]) {
                for m in missed.sorted(by: { $0.date < $1.date }) where m.date > Notifier.lastMissedDate {
                    Notifier.postMissed(number: m.number, name: knownName(m.number, fallback: m.name))
                    Notifier.lastMissedDate = m.date
                }
            }
            if let list = JSONBridge.decode([SmsMessage].self, d["sms"]) {
                list.forEach { self.incoming($0, live: false) }
            }
        }
    }

    private func handleEvent(_ t: String, _ body: [String: Any]) {
        switch t {
        case "status":
            if let s = JSONBridge.decode(PhoneStatus.self, body) { status = s }
        case "call":
            if let c = JSONBridge.decode(CallInfo.self, body["call"]) { apply(call: c) }
        case "missed":
            let rejected = body["rejected"] as? Bool ?? false
            let date = (body["date"] as? NSNumber)?.int64Value ?? 0
            if !rejected && (date == 0 || date > Notifier.lastMissedDate) {
                let num = body["number"] as? String ?? ""
                Notifier.postMissed(number: num, name: knownName(num, fallback: body["name"] as? String ?? ""))
            }
            // The call-log entry for this call may carry a slightly different timestamp.
            if date > 0 { Notifier.lastMissedDate = max(Notifier.lastMissedDate, date + 15_000) }
            if isForeground { loadRecents() }
        case "sms":
            if let m = JSONBridge.decode(SmsMessage.self, body["msg"]) { incoming(m, live: true) }
        case "audio":
            if listening, let s = body["d"] as? String, let d = Data(base64Encoded: s) {
                lastAudioAt = Date()
                audioPlayer.enqueue(d)
            }
        case "listen":
            if body["on"] as? Bool == false {
                // Keep the engine and route; the watchdog asks again in a moment.
                dlog("call audio paused on Android: \(body["reason"] as? String ?? "?")")
                lastAudioAt = .distantPast
            }
        case "sms_status":
            guard let ref = body["ref"] as? String, let state = body["state"] as? String else { return }
            updateOutgoing(ref: ref, state: state)
        default:
            break
        }
    }

    private func apply(call raw: CallInfo) {
        var c = raw
        c.name = knownName(c.number, fallback: c.name)
        let prev = call
        call = c
        if c.state != prev.state { dlog("call \(prev.state) → \(c.state) (\(c.direction)) · callkit \(callKit.hasCall) · fg \(isForeground)") }
        if c.state == "ringing" { dlog("caller name: \(c.name)") }
        if c.state == "ringing" && prev.state != "ringing" {
            if useCallKit && !TestHooks.isActive {
                callScreenMinimized = true // the native call UI takes over
                callKit.reportIncoming(number: c.number, name: c.name) { [weak self] ok in
                    guard let self, !ok, self.call.state == "ringing" else { return }
                    self.callScreenMinimized = false
                    Notifier.postIncomingCall(self.call, simLabel: self.simLabel(self.call.subId))
                }
            } else {
                callScreenMinimized = false
                Notifier.postIncomingCall(c, simLabel: simLabel(c.subId))
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
        if c.state == "offhook" && prev.state == "ringing" {
            callKit.answeredElsewhere() // no-op when it was answered on the native screen
            callScreenMinimized = false
        }
        if c.state != "ringing" { Notifier.removeIncomingCall() }
        if c.state == "offhook" && prev.state == "idle" { callScreenMinimized = false }
        // Outgoing calls also go through the iPhone's call system (CallKit): proper call audio session
        // (never the loudspeaker by surprise), green pill / Dynamic Island, and the app stays alive.
        if c.state == "offhook" && prev.state == "idle" && c.direction == "out" && useCallKit && !TestHooks.isActive {
            callKit.startOutgoing(number: c.number, name: c.name)
        }
        if c.state == "offhook" && c.since > 0 { callKit.outgoingConnected() }
        if c.state == "offhook" && !listening && canListen { startCallAudio() }
        if c.isIdle && !prev.isIdle {
            callKit.ended(missed: prev.state == "ringing")
            stopListeningLocally()
            speakerOn = false
            muted = false
            if isForeground { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.loadRecents() } }
        }
        updateProximity()
    }

    private func incoming(_ raw: SmsMessage, live: Bool) {
        var m = raw
        m.name = knownName(m.address, fallback: m.name)
        let isOpen = isForeground && openThreadId != nil && threads.first(where: { $0.threadId == openThreadId })
            .map { Phone.same($0.address, m.address) } == true
        if Notifier.shouldNotify(m), !isOpen {
            Notifier.postSms(m, simLabel: simLabel(m.subId))
        }
        // Update local caches.
        if let idx = threads.firstIndex(where: { Phone.same($0.address, m.address) }) {
            var t = threads[idx]
            let tid = t.threadId
            var msg = m
            msg.threadId = tid
            var list = messages[tid] ?? []
            if !list.contains(where: { $0.id == msg.id || ($0.body == msg.body && abs($0.date - msg.date) < 120_000 && !$0.out) }) {
                list.append(msg)
                messages[tid] = list
            }
            t.snippet = m.body
            t.date = max(t.date, m.date)
            t.out = false
            if isOpen { markRead(tid, upTo: m.date) } else { t.unread += 1 }
            threads.remove(at: idx)
            threads.insert(t, at: 0)
        }
        if isForeground { scheduleThreadsRefresh() }
    }

    private func scheduleThreadsRefresh() {
        threadsRefreshWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.loadThreads() }
        threadsRefreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }

    // MARK: - Data loading

    func refreshAll() {
        loadThreads()
        loadRecents()
        if !contactsLoaded { loadContacts() }
    }

    func loadThreads(_ done: (() -> Void)? = nil) {
        guard conn.isReady else { done?(); return }
        loadingThreads = true
        client.request("threads", ["limit": 100, "readMarks": readMarks]) { [weak self] r in
            guard let self else { return }
            self.loadingThreads = false
            if case .success(let d) = r, let list = JSONBridge.decode([SmsThread].self, d["threads"]) {
                self.threads = list.map(self.named)
            } else if case .failure(let e) = r {
                self.report(e)
            }
            done?()
        }
    }

    func loadMessages(threadId: Int64, _ done: (() -> Void)? = nil) {
        client.request("messages", ["threadId": threadId, "limit": 150]) { [weak self] r in
            guard let self else { return }
            if case .success(let d) = r, let list = JSONBridge.decode([SmsMessage].self, d["messages"]) {
                // Keep optimistic messages that the provider has not caught up with yet.
                let pendingLocal = (self.messages[threadId] ?? []).filter { m in
                    m.id.hasPrefix("local-") && !list.contains { $0.out && $0.body == m.body && abs($0.date - m.date) < 300_000 }
                }
                self.messages[threadId] = list + pendingLocal
                if self.openThreadId == threadId, let last = list.last(where: { !$0.out }) {
                    self.markRead(threadId, upTo: last.date)
                }
            }
            done?()
        }
    }

    func loadContacts() {
        client.request("contacts", timeout: 30) { [weak self] r in
            guard let self else { return }
            if case .success(let d) = r, let list = JSONBridge.decode([Contact].self, d["contacts"]) {
                self.androidContacts = list
                self.contactsLoaded = true
                self.contactsChanged()
            }
        }
    }

    func loadRecents() {
        guard conn.isReady else { return }
        client.request("calls", ["limit": 150]) { [weak self] r in
            if case .success(let d) = r, let list = JSONBridge.decode([CallLogEntry].self, d["calls"]) {
                guard let self else { return }
                self.recents = list.map(self.named)
            }
        }
    }

    func markThreadOpened(_ threadId: Int64?) {
        openThreadId = threadId
        guard let tid = threadId else { return }
        markRead(tid, upTo: threads.first { $0.threadId == tid }?.date ?? 0)
    }

    private func markRead(_ tid: Int64, upTo date: Int64) {
        // Dates come from the Android phone's clock, so never mix in the iPhone's clock here.
        let latest = max(date, messages[tid]?.last(where: { !$0.out })?.date ?? 0)
        readMarks[String(tid)] = max(readMarks[String(tid)] ?? 0, latest)
        if let i = threads.firstIndex(where: { $0.threadId == tid }) { threads[i].unread = 0 }
    }

    // MARK: - Actions

    func sendSms(to address: String, body: String, subId: Int?, threadId: Int64?, _ done: ((Bool) -> Void)? = nil) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { done?(false); return }
        let localId = "local-" + UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if let tid = threadId {
            let m = SmsMessage(id: localId, threadId: tid, address: address, name: "", body: text, date: now,
                               out: true, status: "sending", read: true, subId: subId)
            messages[tid, default: []].append(m)
        }
        var params: [String: Any] = ["to": address, "body": text]
        if let subId { params["subId"] = subId }
        client.request("send_sms", params) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let d):
                if let ref = d["ref"] as? String { self.outgoing[ref] = (threadId, localId, address) }
                done?(true)
                if threadId == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.loadThreads() } }
            case .failure(let e):
                self.setLocalStatus(threadId: threadId, localId: localId, status: "failed")
                self.report(e)
                done?(false)
            }
        }
    }

    private func updateOutgoing(ref: String, state: String) {
        guard let o = outgoing[ref] else { return }
        let status: String
        switch state {
        case "sent": status = "sent"
        case "delivered": status = "delivered"; outgoing.removeValue(forKey: ref)
        default: status = "failed"; outgoing.removeValue(forKey: ref)
        }
        setLocalStatus(threadId: o.threadId, localId: o.localId, status: status)
        if state == "failed" { toast = "Message to \(o.address) not delivered" }
        if state == "sent", let tid = o.threadId {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.openThreadId == tid else { return }
                self.loadMessages(threadId: tid)
            }
        }
    }

    private func setLocalStatus(threadId: Int64?, localId: String, status: String) {
        guard let tid = threadId, var list = messages[tid], let i = list.firstIndex(where: { $0.id == localId }) else { return }
        list[i].status = status
        messages[tid] = list
    }

    // MARK: - USSD (*140# …)

    enum UssdState: Equatable {
        case running(String)
        case reply(String, String)
        case failed(String, String)
    }

    @Published var ussd: UssdState?

    static func isUssd(_ s: String) -> Bool {
        let n = s.filter { !$0.isWhitespace }
        return n.count >= 3 && n.hasSuffix("#") && (n.hasPrefix("*") || n.hasPrefix("#"))
    }

    func runUssd(_ code: String, subId: Int?) {
        let c = code.filter { $0.isNumber || $0 == "*" || $0 == "#" }
        ussd = .running(c)
        var params: [String: Any] = ["code": c]
        if let subId { params["subId"] = subId }
        client.request("ussd", params, timeout: 45) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let d): self.ussd = .reply(c, d["text"] as? String ?? "")
            case .failure(let e): self.ussd = .failed(c, (e as? LocalizedError)?.errorDescription ?? e.localizedDescription)
            }
        }
    }

    func dial(_ number: String, subId: Int? = nil) {
        if Self.isUssd(number) { runUssd(number, subId: subId); return }
        let n = number.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
        guard !n.isEmpty else { return }
        var params: [String: Any] = ["number": n]
        if let subId { params["subId"] = subId }
        // Show the call screen right away, but only as "requesting" until Android confirms.
        client.request("dial", params) { [weak self] r in
            if case .failure(let e) = r { self?.report(e) }
        }
    }

    // MARK: - Watchdog (background keeper + call audio)

    private var watchdog: Timer?
    private var lastAudioAt = Date.distantPast
    private var lastAudioRequest = Date.distantPast

    /// Every 2 s: keep the silent loop alive in always-connected mode, reconnect a dropped link, and
    /// keep the call audio flowing for as long as a call lasts.
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    private var lastAudioLog = Date.distantPast

    private func tick() {
        syncLiveSignal()
        updateProximity()
        let hasLink = pairing != nil
        if keepConnected && (hasLink || sipAccount?.isComplete == true) && keeper.mayTouchSession() && !keeper.isRunning
            && !TestHooks.isActive {
            dlog("watchdog: restarting background keeper")
            keeper.start()
        }
        if hasLink && (isForeground || keepConnected) && client.mode != nil {
            if case .failed = conn { client.kick() }
            if case .idle = conn { client.kick() }
        }
        guard call.state == "offhook" else { return }
        // iOS stops the audio engine on route changes / interruptions: bring it back.
        if listening { audioPlayer.ensureRunning() }
        if listening && Date().timeIntervalSince(lastAudioLog) > 10 {
            lastAudioLog = Date()
            dlog("call audio: \(audioPlayer.debugLine) · last packet \(Int(Date().timeIntervalSince(lastAudioAt) * 1000))ms ago")
        }
        // Android became ready mid-call: start now.
        if !listening && canListen { startCallAudio() }
        // No audio for a while (capture restarting, link was down…): ask again, quietly.
        if listening && conn.isReady && Date().timeIntervalSince(lastAudioAt) > 4
            && Date().timeIntervalSince(lastAudioRequest) > 5 {
            dlog("watchdog: no call audio, asking Android again")
            requestCallAudio()
        }
    }

    // MARK: - Call audio on iPhone (automatic, always on during calls)

    /// Starts with every call and stays on until the call ends: the engine keeps running (silence
    /// while nothing arrives), so the route never changes and nothing flips on and off.
    private func startCallAudio() {
        guard !listening, call.state == "offhook", canListen else { return }
        dlog("call audio: on")
        listening = true
        iphoneSpeaker = false
        lastAudioAt = Date()
        if callKit.hasCall && callKit.answeredHere {
            // CallKit owns the session; the engine starts (or already runs) on activation.
            if callKit.audioActive { audioPlayer.start(managedByCallKit: true) }
        } else {
            audioPlayer.start()
        }
        audioPlayer.setSpeaker(false) // always the earpiece (or AirPods) first, like a phone call
        requestCallAudio()
    }

    private func requestCallAudio() {
        guard conn.isReady, call.state == "offhook" else { return }
        lastAudioRequest = Date()
        client.request("listen", ["on": true], timeout: 25) { r in
            if case .failure(let e) = r { dlog("call audio request failed: \(e)") }
        }
    }

    private func stopListeningLocally() {
        guard listening else { return }
        listening = false
        iphoneSpeaker = false
        if !(callKit.hasCall && callKit.audioActive) {
            audioPlayer.stop()
            resumeKeeper()
        } // else keep the engine for the native call
        // Back in the background without audio: release the connection shortly, as usual.
        if !isForeground { beginBackgroundTask(seconds: 3) }
    }

    /// Ringing screen → "Remind Me": a reminder to call back in an hour.
    func remindMe(_ c: CallInfo) {
        Notifier.postCallReminder(number: c.number, name: c.name, after: 3600)
        toast = "You'll be reminded in 1 hour"
    }

    /// Ringing screen → "Message": decline and open a new message to the caller.
    func declineWithMessage(_ c: CallInfo) {
        let number = c.number
        endCall()
        guard !number.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.tab = .messages
            self?.pendingCompose = number
        }
    }
    @Published var pendingCompose: String?

    func answer(speaker: Bool = false, _ done: ((Bool) -> Void)? = nil) {
        client.request("answer", ["speaker": speaker]) { [weak self] r in
            switch r {
            case .success: if speaker { self?.speakerOn = true }; done?(true)
            case .failure(let e): self?.report(e); done?(false)
            }
        }
    }

    func endCall(_ done: ((Bool) -> Void)? = nil) {
        client.request(call.state == "ringing" ? "reject" : "hangup") { [weak self] r in
            switch r {
            case .success: done?(true)
            case .failure(let e): self?.report(e); done?(false)
            }
        }
    }

    func toggleSpeaker() {
        let target = !speakerOn
        client.request("speaker", ["on": target]) { [weak self] r in
            switch r {
            case .success(let d): self?.speakerOn = d["on"] as? Bool ?? target
            case .failure(let e): self?.report(e)
            }
        }
    }

    func setMute(_ on: Bool) {
        client.request("mute", ["on": on]) { [weak self] r in
            switch r {
            case .success(let d): self?.muted = d["on"] as? Bool ?? on
            case .failure(let e): self?.report(e)
            }
        }
    }

    func toggleMute() {
        let target = !muted
        client.request("mute", ["on": target]) { [weak self] r in
            switch r {
            case .success(let d): self?.muted = d["on"] as? Bool ?? target
            case .failure(let e): self?.report(e)
            }
        }
    }

    // MARK: - Notification actions (may arrive while the app is in the background)

    func handleNotificationAction(_ action: String, userInfo: [AnyHashable: Any], text: String?, completion: @escaping () -> Void) {
        let kind = userInfo["kind"] as? String ?? ""
        switch action {
        case UNNotificationDefaultActionIdentifier:
            switch kind {
            case "sms": tab = .messages
            case "call": callScreenMinimized = false
            case "missed": tab = .calls
            default: break
            }
            completion()
            return
        case Notifier.actCallback:
            tab = .calls
            if let n = userInfo["number"] as? String, !n.isEmpty {
                client.ensureReady(timeout: 8) { [weak self] ok in
                    if ok { self?.dial(n) }
                    completion()
                }
            } else { completion() }
            return
        default: break
        }

        beginBackgroundTask(seconds: 25)
        client.autoReconnect = true
        client.ensureReady(timeout: 12) { [weak self] ok in
            guard let self else { completion(); return }
            guard ok else {
                Notifier.postInfo("Not Sent", "The Android phone was unavailable.")
                completion()
                return
            }
            let finish: (Bool) -> Void = { _ in completion() }
            switch action {
            case Notifier.actAnswer: self.answer(speaker: false, finish)
            case Notifier.actAnswerSpeaker: self.answer(speaker: true, finish)
            case Notifier.actReject: self.endCall(finish)
            case Notifier.actReply:
                let address = userInfo["address"] as? String ?? ""
                let sub = userInfo["subId"] as? Int
                let tid = self.threads.first { Phone.same($0.address, address) }?.threadId
                self.sendSms(to: address, body: text ?? "", subId: (sub ?? -1) >= 0 ? sub : nil, threadId: tid) { ok in
                    if !ok { Notifier.postInfo("Message Not Sent", address) }
                    completion()
                }
            default:
                completion()
            }
        }
    }

    // MARK: - Helpers

    func report(_ e: Error) {
        guard isForeground else { return }
        toast = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
    }

    var sims: [SimInfo] { status?.sims ?? [] }

    /// The SIM a call/SMS is on; falls back to the default voice SIM.
    func sim(for subId: Int?) -> SimInfo? {
        if let id = subId, id >= 0, let s = sims.first(where: { $0.subId == id }) { return s }
        return sims.first { $0.voiceSim } ?? sims.first
    }

    /// "SIM 2 · Irancell" on dual-SIM phones, nil otherwise.
    func simLabel(_ subId: Int?) -> String? {
        guard sims.count > 1, let id = subId, id >= 0, let s = sims.first(where: { $0.subId == id }) else { return nil }
        return "SIM \(s.slot + 1) · \(s.title)"
    }

    // MARK: - Names (iPhone contacts first, then the Android phone's contacts)

    func displayName(for number: String) -> String? {
        let k = Phone.key(number)
        guard !k.isEmpty else { return nil }
        return iphoneContacts.byKey[k] ?? androidByKey[k]
    }

    /// Best name for a number: iPhone contact, then the name Android sent, then Android contacts.
    func knownName(_ number: String, fallback: String) -> String {
        let k = Phone.key(number)
        if !k.isEmpty, let n = iphoneContacts.byKey[k] { return n }
        if !fallback.isEmpty { return fallback }
        return k.isEmpty ? "" : (androidByKey[k] ?? "")
    }

    private func named(_ t: SmsThread) -> SmsThread {
        var t = t
        t.name = knownName(t.address, fallback: t.name)
        return t
    }

    private func named(_ c: CallLogEntry) -> CallLogEntry {
        var c = c
        c.name = knownName(c.number, fallback: c.name)
        return c
    }

    /// Rebuilds the merged contact list and re-labels what is on screen.
    private func contactsChanged() {
        var map: [String: String] = [:]
        for c in androidContacts {
            for n in c.numbers { let k = Phone.key(n); if !k.isEmpty, map[k] == nil { map[k] = c.name } }
        }
        androidByKey = map
        // Merge: every iPhone contact, plus Android contacts whose numbers the iPhone does not know.
        let iphone = iphoneContacts.list
        let known = iphoneContacts.byKey
        var merged = iphone
        for c in androidContacts where !c.numbers.contains(where: { known[Phone.key($0)] != nil }) {
            merged.append(c)
        }
        merged.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        contacts = merged.enumerated().map { i, c in Contact(id: Int64(i + 1), name: c.name, numbers: c.numbers) }
        threads = threads.map(named)
        recents = recents.map(named)
        if !call.isIdle {
            let n = knownName(call.number, fallback: call.name)
            if n != call.name { call.name = n }
        }
    }
}
