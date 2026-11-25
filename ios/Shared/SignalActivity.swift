import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Live Activity with the Android phone's SIM signal (Lock Screen + Dynamic Island). Shared by the app
/// (which starts and updates it) and the widget extension (which draws it).
@available(iOS 16.1, *)
struct SignalAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Operator name of the main SIM.
        var carrier: String
        /// Bars 0…4.
        var level: Int
        /// "4G", "LTE", "3G"… (may be empty).
        var gen: String
        /// in / out / emergency / off / searching
        var service: String
        /// The iPhone is connected to the Android phone right now.
        var linked: Bool
        /// Bars of a second SIM, if there is one.
        var second: Int?
        /// Android battery percent.
        var battery: Int?
    }

    var device: String
}
#endif
