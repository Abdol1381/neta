import WidgetKit
import SwiftUI
import ActivityKit

@main
struct SIMBridgeWidgets: WidgetBundle {
    var body: some Widget {
        SignalLiveActivity()
    }
}

/// The Android SIM's signal on the Lock Screen and in the Dynamic Island.
struct SignalLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SignalAttributes.self) { ctx in
            LockScreenSignal(state: ctx.state, stale: ctx.isStale, device: ctx.attributes.device)
                .activityBackgroundTint(Color.black.opacity(0.45))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            let s = SignalView(state: ctx.state, stale: ctx.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        s.bars.font(.title3)
                        if !s.genText.isEmpty { Text(s.genText).font(.headline) }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let b = ctx.state.battery, s.live {
                        Label("\(b)%", systemImage: "battery.75percent").font(.subheadline).labelStyle(.titleAndIcon)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(s.line).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            } compactLeading: {
                s.bars
            } compactTrailing: {
                Text(s.live ? (s.genText.isEmpty ? "SIM" : s.genText) : "—").font(.caption2.weight(.semibold))
            } minimal: {
                s.bars
            }
        }
    }
}

/// Shared formatting for the Lock Screen and the Dynamic Island.
struct SignalView {
    let state: SignalAttributes.ContentState
    let stale: Bool

    var live: Bool { state.linked && !stale }
    var inService: Bool { state.service == "in" }
    var genText: String { live && inService ? state.gen : "" }

    var bars: some View {
        Group {
            if !live {
                Image(systemName: "cellularbars", variableValue: 0).foregroundStyle(.secondary)
            } else if !inService {
                Image(systemName: state.service == "off" ? "airplane" : "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "cellularbars", variableValue: Double(max(0, min(4, state.level))) / 4)
            }
        }
    }

    var line: String {
        if !live { return "Android phone not connected" }
        let name = state.carrier.isEmpty ? "SIM" : state.carrier
        switch state.service {
        case "in": return name
        case "emergency": return "\(name) · SOS only"
        case "off": return "Radio off"
        case "out": return "\(name) · No service"
        default: return "\(name) · Searching…"
        }
    }
}

struct LockScreenSignal: View {
    let state: SignalAttributes.ContentState
    let stale: Bool
    let device: String

    var body: some View {
        let s = SignalView(state: state, stale: stale)
        HStack(spacing: 14) {
            s.bars.font(.system(size: 28, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.live ? (state.carrier.isEmpty ? "SIM" : state.carrier) : "Not connected")
                        .font(.headline).lineLimit(1)
                    if !s.genText.isEmpty {
                        Text(s.genText).font(.caption.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(s.live ? (device.isEmpty ? "SIMBridge" : "SIMBridge · \(device)") : "Open SIMBridge to reconnect")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if s.live, let second = state.second {
                VStack(spacing: 2) {
                    Image(systemName: "cellularbars", variableValue: Double(max(0, min(4, second))) / 4)
                    Text("SIM 2").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if s.live, let b = state.battery {
                Text("\(b)%").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
