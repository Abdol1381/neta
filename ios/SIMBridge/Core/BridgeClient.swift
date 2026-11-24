import Foundation
import Network
import CryptoKit
import UIKit

enum ConnState: Equatable {
    case idle
    case connecting
    case authenticating
    case awaitingApproval(code: String)
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
}

enum BridgeError: LocalizedError {
    case notConnected
    case timeout
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the Android phone"
        case .timeout: return "The Android phone did not respond"
        case .server(let code):
            switch code {
            case "permission_denied": return "Permission missing in the Android app"
            case "no_call": return "No active call"
            case "busy": return "Another call is in progress"
            case "unsupported": return "Not supported on this Android phone"
            case "bad_request": return "Invalid number or text"
            case "ussd_failed": return "The carrier did not answer this code"
            case "timeout": return "No reply from the carrier"
            case "dev_no_shizuku", "dev_not_set_up": return "To hear calls on iPhone, finish “Hear calls on iPhone → Set up” in the Android app"
            case "dev_adb_offline": return "The Android phone is not connected to Wireless debugging (Wi-Fi must be on)"
            case "dev_no_permission": return "Allow SIMBridge in Shizuku on the Android phone"
            case "dev_unsupported": return "Call audio needs Android 11 or later"
            case "audio_failed": return "Call audio could not start on the Android phone"
            default: return "Android phone error (\(code))"
            }
        }
    }
}

func dlog(_ s: @autoclosure () -> String) {
    let msg = s()
    DiagLog.add(msg)
    #if DEBUG
    NSLog("[SIMBridge] %@", msg)
    #endif
}

/// Recent events for Settings → Diagnostics (kept in memory, last 400 lines).
enum DiagLog {
    private static var lines: [String] = []
    private static let lock = NSLock()
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func add(_ msg: String) {
        lock.lock()
        lines.append(fmt.string(from: Date()) + "  " + msg)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        lock.unlock()
    }

    static var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

/// Encrypted WebSocket link to the Android agent. Everything runs on the main queue.
final class BridgeClient {
    enum Mode {
        case pair(PairOffer)
        case device(Pairing)
    }

    typealias Completion = (Result<[String: Any], Error>) -> Void

    private(set) var mode: Mode?
    private(set) var state: ConnState = .idle {
        didSet { if state != oldValue { dlog("state \(state)"); onState?(state) } }
    }

    var onState: ((ConnState) -> Void)?
    var onReady: ((_ hosts: [String], _ port: Int?) -> Void)?
    var onEvent: ((_ type: String, _ body: [String: Any]) -> Void)?
    var onPaired: ((Pairing) -> Void)?
    /// denied / unknown_device / pairing_closed
    var onRejected: ((String) -> Void)?

    /// When false, a dropped connection is not retried automatically (e.g. app in background).
    var autoReconnect = true

    private var conn: NWConnection?
    private var racing: [NWConnection] = []
    private var key: SymmetricKey?
    private var pairKeyData = Data()
    private var pending: [String: Completion] = [:]
    private var ridCounter = 0
    private var generation = 0
    private var retryWork: DispatchWorkItem?
    private var retryDelay: TimeInterval = 1
    private var browser: NWBrowser?
    private var browsingFor: String?
    /// LAN addresses the Android phone advertises in its Bonjour TXT record ("h").
    private var bonjour: [String] = []
    private var lastGoodHost: String?
    private var readyWaiters: [(Bool) -> Void] = []
    /// While pairing, failed attempts are retried silently until this moment (covers the
    /// iOS "Local Network" permission prompt and a slow Wi-Fi join).
    private var pairDeadline = Date.distantPast

    // MARK: - Public

    func connect(_ mode: Mode) {
        self.mode = mode
        retryDelay = 1
        if case .pair = mode { pairDeadline = Date().addingTimeInterval(45) }
        if case .device(let p) = mode { startBrowsing(serverId: p.serverId) }
        if case .pair(let o) = mode { startBrowsing(serverId: o.serverId) }
        attempt()
    }

    /// Connects if needed; calls back with true once ready (or false after `timeout`).
    func ensureReady(timeout: TimeInterval, _ done: @escaping (Bool) -> Void) {
        if state.isReady { done(true); return }
        readyWaiters.append(done)
        switch state {
        case .connecting, .authenticating: break
        default: if mode != nil { attempt() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            // Fire only the waiters still pending.
            if !self.readyWaiters.isEmpty && !self.state.isReady {
                let waiters = self.readyWaiters
                self.readyWaiters.removeAll()
                waiters.forEach { $0(false) }
            }
        }
    }

    func disconnect() {
        retryWork?.cancel()
        generation += 1
        teardown()
        state = .idle
    }

    func reset() {
        disconnect()
        mode = nil
        stopBrowsing()
    }

    func request(_ type: String, _ params: [String: Any] = [:], timeout: TimeInterval = 15, _ done: @escaping Completion) {
        guard state.isReady, conn != nil, key != nil else { done(.failure(BridgeError.notConnected)); return }
        ridCounter += 1
        let rid = "r\(ridCounter)"
        var msg = params
        msg["t"] = type
        msg["rid"] = rid
        pending[rid] = done
        sendEncrypted(msg)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            if let cb = self?.pending.removeValue(forKey: rid) { cb(.failure(BridgeError.timeout)) }
        }
    }

    // MARK: - Connection racing

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 16 * 1024 * 1024
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return params
    }

    private func candidates() -> [NWEndpoint] {
        guard let mode else { return [] }
        var hosts: [String] = []
        var port = 8765
        switch mode {
        case .pair(let o): hosts = o.hosts; port = o.port
        case .device(let p): hosts = p.hosts; port = p.port
        }
        for h in bonjour where !hosts.contains(h) { hosts.append(h) }
        if let last = lastGoodHost, let i = hosts.firstIndex(of: last) {
            hosts.remove(at: i)
            hosts.insert(last, at: 0)
        }
        // A full ws:// URL is required: with a bare host:port endpoint Network.framework sends an
        // incomplete WebSocket upgrade request, which servers reject (400 Bad Request).
        return hosts.compactMap { h in
            let hostPart = h.contains(":") ? "[\(h)]" : h
            return URL(string: "ws://\(hostPart):\(port)/").map { NWEndpoint.url($0) }
        }
    }

    private func attempt() {
        guard mode != nil else { return }
        retryWork?.cancel()
        teardown()
        generation += 1
        let gen = generation
        let endpoints = candidates()
        guard !endpoints.isEmpty else {
            state = .connecting
            fail("Android phone not found. Both phones must be on the same Wi-Fi.")
            return
        }
        state = .connecting
        dlog("attempt \(endpoints)")
        for ep in endpoints {
            let c = NWConnection(to: ep, using: Self.parameters())
            racing.append(c)
            c.stateUpdateHandler = { [weak self, weak c] st in
                guard let self, let c else { return }
                self.raceUpdate(c, ep, st, gen)
            }
            c.start(queue: .main)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, gen == self.generation, self.conn == nil else { return }
            self.fail("Android phone unavailable")
        }
    }

    private func raceUpdate(_ c: NWConnection, _ ep: NWEndpoint, _ st: NWConnection.State, _ gen: Int) {
        guard gen == generation else { c.cancel(); return }
        dlog("race \(ep) -> \(st)")
        switch st {
        case .ready:
            guard conn == nil else { c.cancel(); return }
            conn = c
            racing.removeAll { $0 === c }
            racing.forEach { $0.cancel() }
            racing.removeAll()
            if case .url(let u) = ep, let host = u.host { lastGoodHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
            c.stateUpdateHandler = { [weak self, weak c] st in
                guard let self, let c, c === self.conn else { return }
                switch st {
                case .failed, .cancelled, .waiting: self.connectionLost()
                default: break
                }
            }
            receive(c)
            sendHello()
        case .failed:
            c.cancel()
            racing.removeAll { $0 === c }
            if racing.isEmpty && conn == nil { fail("Android phone unavailable") }
        case .waiting:
            // Not fatal (e.g. Local Network permission pending, Wi-Fi joining). The attempt timeout decides.
            break
        case .cancelled:
            racing.removeAll { $0 === c }
        default:
            break
        }
    }

    private func teardown() {
        racing.forEach { $0.stateUpdateHandler = nil; $0.cancel() }
        racing.removeAll()
        if let c = conn { c.stateUpdateHandler = nil; c.cancel() }
        conn = nil
        key = nil
        let callbacks = pending
        pending.removeAll()
        callbacks.values.forEach { $0(.failure(BridgeError.notConnected)) }
    }

    private func connectionLost() {
        guard conn != nil else { return }
        teardown()
        fail("Connection lost")
    }

    private func fail(_ reason: String) {
        teardown()
        if case .pair = mode, Date() < pairDeadline {
            state = .connecting
            retryWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.attempt() }
            retryWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
            return
        }
        state = .failed(reason)
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard autoReconnect, mode != nil else { return }
        if case .pair = mode { return } // pairing is user-driven
        retryWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.attempt() }
        retryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: w)
        retryDelay = min(retryDelay * 2, 15)
    }

    /// Network came back or the app became active: try again right away.
    func kick() {
        guard mode != nil else { return }
        switch state {
        case .ready, .connecting, .authenticating, .awaitingApproval: return
        default:
            retryDelay = 1
            attempt()
        }
    }

    // MARK: - Bonjour

    private func startBrowsing(serverId: String) {
        if browsingFor == serverId, browser != nil { return }
        stopBrowsing()
        browsingFor = serverId
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_simbridge._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let found: [String] = results.flatMap { r -> [String] in
                guard case let .bonjour(txt) = r.metadata, txt["sid"] == serverId, let h = txt["h"] else { return [] }
                return h.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            let wasEmpty = self.bonjour.isEmpty
            self.bonjour = found
            if wasEmpty && !found.isEmpty { self.kick() }
        }
        b.start(queue: .main)
        browser = b
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        browsingFor = nil
        bonjour = []
    }

    // MARK: - Framing

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self, weak c] data, context, _, error in
            guard let self, let c, c === self.conn else { return }
            if let error { dlog("receive error \(error)"); self.connectionLost(); return }
            if let data, let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .binary: self.handleBinary(data)
                case .text: self.handleText(data)
                case .close: self.connectionLost(); return
                default: break
                }
            }
            if c === self.conn { self.receive(c) }
        }
    }

    private func sendText(_ obj: [String: Any]) {
        guard let c = conn, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        c.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func sendEncrypted(_ obj: [String: Any]) {
        guard let c = conn, let key,
              let plain = try? JSONSerialization.data(withJSONObject: obj),
              let frame = WireCrypto.seal(plain, key: key) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "binary", metadata: [meta])
        c.send(content: frame, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    // MARK: - Protocol

    private func sendHello() {
        guard let mode else { return }
        state = .authenticating
        switch mode {
        case .pair(let o):
            pairKeyData = o.key
            key = SymmetricKey(data: o.key)
            sendText(["t": "hello", "mode": "pair", "v": 1])
        case .device(let p):
            key = SymmetricKey(data: p.key)
            sendText(["t": "hello", "mode": "dev", "id": p.clientId, "v": 1])
        }
    }

    private func handleText(_ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if obj["t"] as? String == "error" {
            let code = obj["code"] as? String ?? "error"
            autoReconnect = autoReconnect && code != "unknown_device"
            onRejected?(code)
        }
    }

    private func handleBinary(_ data: Data) {
        guard let key else { return }
        guard let plain = WireCrypto.open(data, key: key) else { dlog("decrypt failed (\(data.count) bytes)"); return }
        guard
              let obj = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any],
              let t = obj["t"] as? String else { return }
        dlog("recv \(t)")

        switch t {
        case "challenge":
            guard let n = obj["n"] as? String else { return }
            if case .pair(let o) = mode {
                if let sid = obj["sid"] as? String, sid != o.serverId { connectionLost(); return }
                let code = WireCrypto.verificationCode(pairingKey: pairKeyData, nonce: Data(base64Encoded: n) ?? Data())
                state = .awaitingApproval(code: code)
            }
            sendEncrypted(["t": "auth", "n": n, "name": UIDevice.current.name, "model": Self.modelIdentifier()])

        case "ready":
            retryDelay = 1
            state = .ready
            let hosts = obj["hosts"] as? [String] ?? []
            let port = obj["port"] as? Int
            onReady?(hosts, port)
            let waiters = readyWaiters
            readyWaiters.removeAll()
            waiters.forEach { $0(true) }

        case "paired":
            guard case .pair(let o) = mode, let id = obj["id"] as? String, let k = obj["key"] as? String,
                  let kd = Data(base64Encoded: k), kd.count == 32 else { return }
            let p = Pairing(serverId: obj["sid"] as? String ?? o.serverId, clientId: id, keyB64: k,
                            name: obj["name"] as? String ?? o.name, hosts: o.hosts, port: o.port)
            onPaired?(p)

        case "denied":
            onRejected?("denied")

        case "res":
            guard let rid = obj["rid"] as? String, let cb = pending.removeValue(forKey: rid) else { return }
            if obj["ok"] as? Bool == true {
                cb(.success(obj["data"] as? [String: Any] ?? [:]))
            } else {
                cb(.failure(BridgeError.server(obj["err"] as? String ?? "error")))
            }

        case "pong":
            if let rid = obj["rid"] as? String, let cb = pending.removeValue(forKey: rid) { cb(.success(obj)) }

        default:
            onEvent?(t, obj)
        }
    }

    static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        return mirror.children.reduce(into: "") { acc, el in
            if let v = el.value as? Int8, v != 0 { acc.append(Character(UnicodeScalar(UInt8(v)))) }
        }
    }
}
