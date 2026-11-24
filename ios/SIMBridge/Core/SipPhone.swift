import Foundation
import CallKit
import AVFoundation
import Security
import linphonesw

/// The user's internet phone line (SIP account). Calls to the SIM are forwarded to `lineNumber` by
/// the operator, so they ring here with real two-way audio through the iPhone's mic and speaker.
struct SipAccount: Codable, Equatable {
    var domain: String = ""
    var username: String = ""
    var password: String = ""
    var transport: String = "udp"   // udp / tcp / tls
    var proxy: String = ""           // optional outbound server (host[:port]); empty = domain
    var lineNumber: String = ""      // the VoIP line's phone number (call-forwarding target)

    var isComplete: Bool { !domain.isEmpty && !username.isEmpty && !password.isEmpty }
}

enum SipAccountStore {
    private static let service = "app.simbridge.sip"

    static func load() -> SipAccount? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "account", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
           let a = try? JSONDecoder().decode(SipAccount.self, from: d) { return a }
        guard let url = fileURL, let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SipAccount.self, from: d)
    }

    static func save(_ a: SipAccount?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "account"]
        SecItemDelete(base as CFDictionary)
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        guard let a, let d = try? JSONEncoder().encode(a) else { return }
        var add = base
        add[kSecValueData as String] = d
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess, let url = fileURL {
            try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("sip.json")
    }
}

/// SIP phone (Linphone) with the iPhone's native call UI (CallKit).
final class SipPhone: NSObject {
    /// off / registering / ok / failed
    private(set) var registration = "off"
    private(set) var registrationMessage = ""
    var onChange: (() -> Void)?
    /// A SIP call started or ended (for pausing the background keeper etc.).
    var onCallActiveChanged: ((Bool) -> Void)?

    private var core: Core?
    private var delegate: CoreDelegate?
    private let provider: CXProvider
    private let controller = CXCallController()
    /// CallKit UUID <-> Linphone call
    private var calls: [UUID: Call] = [:]
    private var outgoingNumbers: [UUID: String] = [:]
    private(set) var account: SipAccount?

    var hasCall: Bool { !calls.isEmpty || !outgoingNumbers.isEmpty }

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.phoneNumber, .generic]
        config.includesCallsInRecents = true
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    // MARK: - Account

    func configure(_ acc: SipAccount?) {
        account = acc
        guard let acc, acc.isComplete else {
            stopCore()
            setRegistration("off", "")
            return
        }
        do {
            let core = try ensureCore()
            core.clearAccounts()
            core.clearAllAuthInfo()
            let transport: TransportType = acc.transport == "tls" ? .Tls : (acc.transport == "tcp" ? .Tcp : .Udp)
            let auth = try Factory.Instance.createAuthInfo(username: acc.username, userid: "", passwd: acc.password,
                                                           ha1: "", realm: "", domain: acc.domain)
            let params = try core.createAccountParams()
            let identity = try Factory.Instance.createAddress(addr: "sip:\(acc.username)@\(acc.domain)")
            try params.setIdentityaddress(newValue: identity)
            let server = try Factory.Instance.createAddress(addr: "sip:" + (acc.proxy.isEmpty ? acc.domain : acc.proxy))
            try server.setTransport(newValue: transport)
            try params.setServeraddress(newValue: server)
            params.registerEnabled = true
            let account = try core.createAccount(params: params)
            core.addAuthInfo(info: auth)
            try core.addAccount(account: account)
            core.defaultAccount = account
            setRegistration("registering", "")
        } catch {
            setRegistration("failed", "\(error)")
        }
    }

    private func ensureCore() throws -> Core {
        if let core { return core }
        let core = try Factory.Instance.createCore(configPath: "", factoryConfigPath: "", systemContext: nil)
        core.callkitEnabled = true      // CallKit owns the audio session
        core.keepAliveEnabled = true    // keep NAT bindings open for incoming calls
        core.videoCaptureEnabled = false
        core.videoDisplayEnabled = false
        let d = CoreDelegateStub(
            onCallStateChanged: { [weak self] (_: Core, call: Call, state: Call.State, message: String) in
                self?.callStateChanged(call, state, message)
            },
            onAccountRegistrationStateChanged: { [weak self] (_: Core, _: Account, state: RegistrationState, message: String) in
                switch state {
                case .Ok: self?.setRegistration("ok", "")
                case .Failed: self?.setRegistration("failed", message)
                case .Progress: self?.setRegistration("registering", "")
                case .Cleared, .None: self?.setRegistration("off", "")
                default: break
                }
            }
        )
        core.addDelegate(delegate: d)
        delegate = d
        try core.start()
        self.core = core
        return core
    }

    private func stopCore() {
        guard let core else { return }
        core.clearAccounts()
        core.clearAllAuthInfo()
        core.stop()
        if let delegate { core.removeDelegate(delegate: delegate) }
        self.core = nil
        delegate = nil
    }

    private func setRegistration(_ s: String, _ msg: String) {
        registration = s
        registrationMessage = msg
        dlog("sip registration: \(s) \(msg)")
        onChange?()
    }

    /// Re-register after network changes / coming back to the foreground.
    func refreshRegistration() {
        core?.refreshRegisters()
    }

    // MARK: - Calls

    private func callStateChanged(_ call: Call, _ state: Call.State, _ message: String) {
        switch state {
        case .IncomingReceived:
            let id = UUID()
            calls[id] = call
            onCallActiveChanged?(true)
            let number = call.remoteAddress?.username ?? ""
            let name = call.remoteAddress?.displayName ?? ""
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .phoneNumber, value: number.isEmpty ? "—" : number)
            update.localizedCallerName = name.isEmpty ? (AppModel.shared.displayName(for: number) ?? nil) : name
            update.hasVideo = false
            update.supportsDTMF = true
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            core?.configureAudioSession()
            provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
                if error != nil {
                    // iOS refused (e.g. Focus): decline so the caller is not left ringing forever.
                    try? call.decline(reason: .Busy)
                    DispatchQueue.main.async { self?.calls[id] = nil }
                }
            }
        case .OutgoingInit, .OutgoingProgress:
            if let id = outgoingNumbers.first?.key, calls[id] == nil {
                calls[id] = call
                outgoingNumbers[id] = nil
                provider.reportOutgoingCall(with: id, startedConnectingAt: Date())
            }
        case .Connected, .StreamsRunning:
            if let id = uuid(for: call), call.dir == .Outgoing {
                provider.reportOutgoingCall(with: id, connectedAt: Date())
            }
        case .End, .Error, .Released:
            if let id = uuid(for: call) {
                let reason: CXCallEndedReason = state == .Error ? .failed : .remoteEnded
                provider.reportCall(with: id, endedAt: Date(), reason: reason)
                calls[id] = nil
            }
            if !hasCall { onCallActiveChanged?(false) }
        default:
            break
        }
    }

    private func uuid(for call: Call) -> UUID? {
        calls.first { $0.value === call }?.key
    }

    /// Outgoing call through the internet line (caller ID = the VoIP line's number).
    func startCall(_ number: String) -> Bool {
        guard registration == "ok", let acc = account else { return false }
        let digits = number.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
        guard !digits.isEmpty, !acc.domain.isEmpty else { return false }
        let id = UUID()
        outgoingNumbers[id] = digits
        onCallActiveChanged?(true)
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .phoneNumber, value: digits))
        controller.request(CXTransaction(action: action)) { [weak self] error in
            if error != nil {
                DispatchQueue.main.async {
                    self?.outgoingNumbers[id] = nil
                    if self?.hasCall == false { self?.onCallActiveChanged?(false) }
                }
            }
        }
        return true
    }
}

extension SipPhone: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        for call in calls.values { try? call.terminate() }
        calls.removeAll()
        outgoingNumbers.removeAll()
        onCallActiveChanged?(false)
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard let core, let acc = account, let number = outgoingNumbers[action.callUUID] else { action.fail(); return }
        do {
            let address = try Factory.Instance.createAddress(addr: "sip:\(number)@\(acc.domain)")
            let params = try core.createCallParams(call: nil)
            params.mediaEncryption = .None
            core.configureAudioSession()
            if core.inviteAddressWithParams(addr: address, params: params) == nil {
                action.fail()
                outgoingNumbers[action.callUUID] = nil
                return
            }
            action.fulfill()
        } catch {
            action.fail()
            outgoingNumbers[action.callUUID] = nil
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let call = calls[action.callUUID] else { action.fail(); return }
        do {
            try call.accept()
            action.fulfill()
        } catch {
            action.fail()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let call = calls[action.callUUID] {
            if call.state == .IncomingReceived {
                try? call.decline(reason: .Declined)
            } else {
                try? call.terminate()
            }
        }
        outgoingNumbers[action.callUUID] = nil
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        core?.micEnabled = !action.isMuted
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        if let call = calls[action.callUUID], let c = action.digits.first {
            try? call.sendDtmf(dtmf: CChar(c.asciiValue ?? 0))
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        core?.activateAudioSession(activated: true)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        core?.activateAudioSession(activated: false)
    }
}
