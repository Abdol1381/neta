import SwiftUI

/// One SIM's signal, carrier and network — like the Cellular rows in iPhone Settings.
struct SimRow: View {
    var sim: SimInfo
    var multi: Bool

    var body: some View {
        HStack(spacing: 14) {
            SignalBarsView(level: sim.level, inService: sim.inService, height: 20, barWidth: 4.5)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(sim.title).font(.body)
                    if !sim.gen.isEmpty { Tag(text: sim.gen, color: .secondary) }
                    if sim.roaming { Tag(text: "Roaming", color: Theme.fair) }
                }
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text(quality.0).font(.subheadline).foregroundStyle(quality.1)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if multi { parts.append("SIM \(sim.slot + 1)") }
        parts.append(sim.serviceText)
        if let dbm = sim.dbm { parts.append("\(dbm) dBm") }
        if multi {
            let roles = [sim.smsSim ? "Messages" : nil, sim.voiceSim ? "Calls" : nil].compactMap { $0 }
            if !roles.isEmpty { parts.append("Default for " + roles.joined(separator: " & ")) }
        }
        return parts.joined(separator: " · ")
    }

    private var quality: (String, Color) {
        guard sim.inService else { return ("—", Theme.muted) }
        switch sim.level {
        case 4: return ("Excellent", Theme.good)
        case 3: return ("Good", Theme.good)
        case 2: return ("Fair", Theme.fair)
        case 1: return ("Poor", Theme.poor)
        default: return ("No Signal", Theme.poor)
        }
    }
}
