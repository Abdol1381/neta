import Foundation

struct SimInfo: Codable, Identifiable, Equatable {
    var subId: Int
    var slot: Int
    var carrier: String
    var name: String
    var number: String
    var level: Int
    var dbm: Int?
    var net: String
    var gen: String
    var service: String
    var roaming: Bool
    var smsSim: Bool
    var voiceSim: Bool
    var dataSim: Bool

    var id: Int { subId }
    var inService: Bool { service == "in" }
    var title: String { carrier.isEmpty ? name : carrier }

    var serviceText: String {
        switch service {
        case "in": return "در سرویس"
        case "out": return "بدون آنتن"
        case "emergency": return "فقط اضطراری"
        case "off": return "رادیو خاموش"
        default: return "در حال بررسی"
        }
    }
}

struct BatteryInfo: Codable, Equatable {
    var level: Int
    var charging: Bool
}

struct DeviceInfo: Codable, Equatable {
    var model: String
    var android: String
}

struct PhoneStatus: Codable, Equatable {
    var sims: [SimInfo]
    var battery: BatteryInfo
    var airplane: Bool
    var device: DeviceInfo
    var perms: [String: Bool]
}

struct CallInfo: Codable, Equatable {
    var state: String      // idle / ringing / offhook
    var number: String
    var name: String
    var direction: String  // in / out
    var since: Int64
    var subId: Int? = nil   // SIM the call is on (dual SIM); nil/-1 when unknown

    static let idle = CallInfo(state: "idle", number: "", name: "", direction: "", since: 0)
    var isIdle: Bool { state == "idle" }
    var display: String { !name.isEmpty ? name : (!number.isEmpty ? number : "شماره نامشخص") }
}

struct SmsMessage: Codable, Identifiable, Equatable {
    var id: String
    var threadId: Int64?
    var address: String
    var name: String
    var body: String
    var date: Int64
    var out: Bool
    var status: String     // ok / sending / failed / sent / delivered
    var read: Bool
    var subId: Int?
}

struct SmsThread: Codable, Identifiable, Equatable {
    var threadId: Int64
    var address: String
    var name: String
    var snippet: String
    var date: Int64
    var out: Bool
    var unread: Int

    var id: Int64 { threadId }
    var title: String { name.isEmpty ? address : name }
}

struct CallLogEntry: Codable, Identifiable, Equatable {
    var id: Int64
    var number: String
    var name: String
    var date: Int64
    var duration: Int64
    var type: String       // in / out / missed / rejected / blocked / other

    var title: String { name.isEmpty ? (number.isEmpty ? "ناشناس" : number) : name }
}

struct Contact: Codable, Identifiable, Equatable {
    var id: Int64
    var name: String
    var numbers: [String]
}

enum JSONBridge {
    static func decode<T: Decodable>(_ type: T.Type, _ any: Any?) -> T? {
        guard let any, !(any is NSNull), JSONSerialization.isValidJSONObject(any) || any is [Any] || any is [String: Any] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            #if DEBUG
            print("decode \(T.self) failed: \(error)")
            #endif
            return nil
        }
    }
}

enum Phone {
    /// Digits only, last 10 — good enough to match +98912… with 0912….
    static func key(_ s: String) -> String {
        let digits = s.filter { $0.isNumber }
        return String(digits.suffix(10))
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let ka = key(a), kb = key(b)
        if ka.isEmpty || kb.isEmpty { return a == b }
        return ka == kb
    }

    static func ltr(_ s: String) -> String { "\u{200E}" + s }

    /// Isolates a name/number of unknown direction inside a Persian sentence (FSI … PDI).
    static func iso(_ s: String) -> String { "\u{2068}" + s + "\u{2069}" }
}
