import Foundation
import CryptoKit

/// Must match the Android side (`core/Crypto.kt`):
/// frame = nonce(12) || ciphertext || tag(16), AES-256-GCM, AAD = direction label.
enum WireCrypto {
    static let serverToClient = Data("simbridge-s2c".utf8)
    static let clientToServer = Data("simbridge-c2s".utf8)

    static func seal(_ plain: Data, key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(), authenticating: clientToServer) else { return nil }
        return box.combined
    }

    static func open(_ frame: Data, key: SymmetricKey) -> Data? {
        guard frame.count >= 28, let box = try? AES.GCM.SealedBox(combined: frame) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: serverToClient)
    }

    /// 4-digit code shown on both phones while pairing.
    static func verificationCode(pairingKey: Data, nonce: Data) -> String {
        var d = Data("simbridge-verify".utf8)
        d.append(pairingKey)
        d.append(nonce)
        let h = Array(SHA256.hash(data: d))
        let v = (UInt32(h[0]) << 24) | (UInt32(h[1]) << 16) | (UInt32(h[2]) << 8) | UInt32(h[3])
        return String(format: "%04u", v % 10000)
    }

    /// First 8 bytes of SHA-256(serverId) — exposed by the Android BLE service so we only bind to our own phone.
    static func bleId(serverId: String) -> Data {
        Data(Array(SHA256.hash(data: Data(serverId.utf8))).prefix(8))
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        return Data(base64Encoded: b)
    }
}
