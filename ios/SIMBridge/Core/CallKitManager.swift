import Foundation
import CallKit
import AVFoundation

/// Shows the Android phone's incoming calls with the iPhone's own call UI (full screen when locked),
/// and maps the native Answer / Decline / End / Mute buttons to the Android phone.
/// After answering, the call downlink audio plays inside the CallKit audio session.
final class CallKitManager: NSObject {
    private let provider: CXProvider
    private let controller = CXCallController()
    private(set) var currentId: UUID?
    private(set) var answeredHere = false
    private(set) var audioActive = false
    private(set) var outgoing = false
    private var connectedReported = false

    var onAnswer: ((@escaping (Bool) -> Void) -> Void)?
    var onEnd: ((@escaping (Bool) -> Void) -> Void)?
    var onMute: ((Bool) -> Void)?
    var onAudioActivated: (() -> Void)?
    var onAudioDeactivated: (() -> Void)?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.phoneNumber]
        config.includesCallsInRecents = true
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    var hasCall: Bool { currentId != nil }

    /// Reports a ringing call. `done(false)` means iOS refused (e.g. Do Not Disturb, Focus) — show
    /// the in-app screen and notification instead.
    func reportIncoming(number: String, name: String, _ done: @escaping (Bool) -> Void) {
        if currentId != nil { done(true); return }
        let id = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number.isEmpty ? "—" : number)
        update.localizedCallerName = name.isEmpty ? nil : name
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        configureAudioSession()
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    dlog("callkit refused: \(error)")
                    done(false)
                    return
                }
                self?.currentId = id
                self?.answeredHere = false
                dlog("callkit reported incoming")
                done(true)
            }
        }
    }

    /// Puts an outgoing Android call into the iPhone's call system. The in-app screen stays the UI; iOS
    /// adds the green pill / Dynamic Island and manages the call audio session.
    func startOutgoing(number: String, name: String) {
        guard currentId == nil else { return }
        let id = UUID()
        let handle = CXHandle(type: .phoneNumber, value: number.isEmpty ? "—" : number)
        currentId = id
        answeredHere = true
        outgoing = true
        connectedReported = false
        configureAudioSession()
        controller.request(CXTransaction(action: CXStartCallAction(call: id, handle: handle))) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.currentId == id else { return }
                if let error {
                    dlog("callkit outgoing refused: \(error)")
                    self.reset()
                    return
                }
                let u = CXCallUpdate()
                u.remoteHandle = handle
                u.localizedCallerName = name.isEmpty ? nil : name
                u.hasVideo = false
                u.supportsHolding = false
                u.supportsGrouping = false
                u.supportsUngrouping = false
                u.supportsDTMF = false
                self.provider.reportCall(with: id, updated: u)
                dlog("callkit outgoing started")
            }
        }
    }

    /// The other side picked up.
    func outgoingConnected() {
        guard let id = currentId, outgoing, !connectedReported else { return }
        connectedReported = true
        provider.reportOutgoingCall(with: id, connectedAt: Date())
    }

    /// The Android call was answered somewhere other than this CallKit screen (on Android, or with the
    /// in-app button): dismiss the native ringing UI.
    func answeredElsewhere() {
        guard let id = currentId, !answeredHere, !outgoing else { return }
        provider.reportCall(with: id, endedAt: Date(), reason: .answeredElsewhere)
        reset()
    }

    /// The Android call ended (caller hung up, missed, or ended on Android).
    func ended(missed: Bool) {
        guard let id = currentId else { return }
        provider.reportCall(with: id, endedAt: Date(), reason: missed ? .unanswered : .remoteEnded)
        reset()
    }

    /// Ends the native call from the app UI (e.g. the in-app hang-up button).
    func requestEnd() {
        guard let id = currentId else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: id))) { _ in }
    }

    private func reset() {
        currentId = nil
        answeredHere = false
        audioActive = false
        outgoing = false
        connectedReported = false
    }

    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
    }
}

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        reset()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard action.callUUID == currentId, let onAnswer else { action.fail(); return }
        answeredHere = true
        onAnswer { ok in
            if ok {
                action.fulfill()
            } else {
                self.answeredHere = false
                action.fail()
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard action.callUUID == currentId else { action.fail(); return }
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard action.callUUID == currentId else { action.fulfill(); return }
        let finish = { action.fulfill(); self.reset() }
        if let onEnd { onEnd { _ in finish() } } else { finish() }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        onMute?(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioActive = true
        onAudioActivated?()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        audioActive = false
        onAudioDeactivated?()
    }
}
