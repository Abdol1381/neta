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
        name = (q["n"]?.isEmpty == false ? q["n"]! : "Android")
        port = Int(q["p"] ?? "") ?? 8765
        hosts = (q["h"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self.key = key
    }
}

enum PairingStore {
    private static let service = "app.simbridge.pairing"
    private static let account = "primary"

    static func load() -> Pairing? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
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
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
