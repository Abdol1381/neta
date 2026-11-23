import Foundation
import Security

/// Long-term trust with one Android phone. Stored in the Keychain (available after first unlock,
/// so background wakes work while the iPhone is locked).
struct Pairing: Codable, Equatable {
    var serverId: String
    var clientId: String
    var keyB64: String
    var name: String
    var hosts: [String]
    var port: Int

    var key: Data { Data(base64Encoded: keyB64) ?? Data() }
}

/// Contents of the QR shown by the Android app.
struct PairOffer: Equatable {
    let serverId: String
    let name: String
    let port: Int
    let hosts: [String]
    let key: Data

    /// simbridge://pair?v=1&sid=…&n=…&p=8765&h=ip1,ip2&k=<base64url>
    init?(string: String) {
        guard let comps = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme?.lowercased() == "simbridge", comps.host?.lowercased() == "pair" else { return nil }
        var q: [String: String] = [:]
        comps.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        guard let sid = q["sid"], !sid.isEmpty,
              let k = q["k"], let key = WireCrypto.base64URLDecode(k), key.count == 32 else { return nil }
        serverId = sid
        let n = (q["n"] ?? "").replacingOccurrences(of: "+", with: " ")
        name = n.isEmpty ? "Android" : n
        port = Int(q["p"] ?? "") ?? 8765
        hosts = (q["h"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self.key = key
    }
}

/// Keychain first; if the Keychain is unavailable (e.g. a build without keychain entitlements),
/// falls back to a file in Application Support protected until first unlock, so a pairing is
/// never silently lost.
enum PairingStore {
    private static let service = "app.simbridge.pairing"
    private static let account = "primary"

    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pairing.json")
    }

    static func load() -> Pairing? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
           let p = try? JSONDecoder().decode(Pairing.self, from: data) {
            return p
        }
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    @discardableResult
    static func save(_ p: Pairing) -> Bool {
        guard let data = try? JSONEncoder().encode(p) else { return false }
        delete()
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecSuccess { return true }
        dlog("keychain save failed (\(status)); using protected file")
        guard let url = fileURL else { return false }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var u = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? u.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    static func delete() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }
}
