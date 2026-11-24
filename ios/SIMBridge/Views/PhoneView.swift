import SwiftUI
import AudioToolbox

// MARK: - Calls tab (like the Phone app's Recents / Calls)

struct RecentsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var missedOnly = false
    @State private var detail: CallLogEntry?

    private var items: [CallLogEntry] {
        missedOnly ? model.recents.filter { $0.type == "missed" } : model.recents
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    EmptyState(icon: "phone", title: missedOnly ? "No Missed Calls" : "No Recents",
                               subtitle: "Calls on the Android phone's SIM appear here.")
                } else {
                    List(items) { c in
                        RecentRow(entry: c, missed: c.type == "missed" || c.type == "rejected") {
                            detail = c
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if !c.number.isEmpty { model.dial(c.number) } }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 12))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Recents")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $missedOnly) {
                        Text("All").tag(false)
                        Text("Missed").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }
            .refreshable { model.loadRecents() }
            .onAppear {
                model.loadRecents()
                model.markMissedSeen()
            }
            .sheet(item: $detail) { c in
                CallInfoSheet(entry: c).environmentObject(model)
                    .presentationDetents([.medium])
            }
        }
    }
}

/// One row of Recents: name (red when missed), call kind, time and the blue (i) button.
struct RecentRow: View {
    var entry: CallLogEntry
    var missed: Bool
    var info: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "phone.arrow.up.right.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .opacity(entry.type == "out" ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name.isEmpty ? entry.title : entry.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(missed ? IOSColor.callRed : .primary)
                    .lineLimit(1)
                Text(kind).font(.subheadline).foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            Text(Fmt.short(entry.date)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Button(action: info) {
                Image(systemName: "info.circle").font(.system(size: 21)).foregroundStyle(IOSColor.iMessageBlue)
            }
            .buttonStyle(.borderless)
        }
    }

    private var kind: String {
        switch entry.type {
        case "in": return "Incoming"
        case "out": return "Outgoing"
        case "missed": return "Missed"
        case "rejected": return "Declined"
        case "blocked": return "Blocked"
        default: return "Call"
        }
    }
}

/// Call details like the (i) page: name, number, actions and the call itself.
struct CallInfoSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var entry: CallLogEntry
    @State private var compose: String?

    var body: some View {
        VStack(spacing: 14) {
            Avatar(name: entry.name.isEmpty ? entry.number : entry.name, size: 84).padding(.top, 24)
            Text(entry.name.isEmpty ? entry.title : entry.name).font(.title2.weight(.semibold))
            if !entry.name.isEmpty { Text(entry.number).foregroundStyle(.secondary) }
            GlassGroup {
                HStack(spacing: 10) {
                    actionButton("message", "message.fill") { compose = entry.number }
                    actionButton("call", "phone.fill") { dismiss(); model.dial(entry.number) }
                }
            }
            .padding(.horizontal, 24)
            .disabled(entry.number.isEmpty)
            VStack(alignment: .leading, spacing: 4) {
                Text(Fmt.stamp(entry.date)).font(.subheadline.weight(.semibold))
                Text(entry.duration > 0 ? "\(typeText) · \(Fmt.duration(entry.duration))" : typeText)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 24)
            Spacer()
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(item: Binding(get: { compose.map { ComposeTarget(number: $0) } }, set: { compose = $0?.number })) { t in
            ComposeView(initialNumber: t.number).environmentObject(model)
        }
    }

    private var typeText: String {
        switch entry.type {
        case "in": return "Incoming Call"
        case "out": return "Outgoing Call"
        case "missed": return "Missed Call"
        case "rejected": return "Declined Call"
        default: return "Call"
        }
    }

    private func actionButton(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.caption.weight(.medium))
            }
            .foregroundStyle(IOSColor.iMessageBlue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Keypad tab (like the Phone app's Keypad)

struct KeypadTab: View {
    var body: some View {
        KeypadView()
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }
}

struct KeypadView: View {
    @EnvironmentObject var model: AppModel
    @State private var number = ""
    /// Set by a long press so the button tap that follows on finger-up is ignored.
    @State private var suppressTap = false
    @State private var subId: Int?
    @State private var useVoip = false

    private struct Key: Identifiable {
        let digit: String
        let letters: String
        var id: String { digit }
    }

    private let keys: [Key] = [
        Key(digit: "1", letters: ""), Key(digit: "2", letters: "ABC"), Key(digit: "3", letters: "DEF"),
        Key(digit: "4", letters: "GHI"), Key(digit: "5", letters: "JKL"), Key(digit: "6", letters: "MNO"),
        Key(digit: "7", letters: "PQRS"), Key(digit: "8", letters: "TUV"), Key(digit: "9", letters: "WXYZ"),
        Key(digit: "*", letters: ""), Key(digit: "0", letters: "+"), Key(digit: "#", letters: ""),
    ]

    var body: some View {
        GeometryReader { geo in
            // Size keys to the space available so the pad fits from iPhone SE to Pro Max.
            let key = min(80, max(58, (geo.size.height - 240) / 5.1))
            let gap = key * 0.22
            VStack(spacing: gap) {
                Spacer(minLength: 4)
                VStack(spacing: 6) {
                    Text(number.isEmpty ? " " : number)
                        .font(.system(size: 38, weight: .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .frame(maxWidth: .infinity)
                    Button {
                        // "Add Number" like iOS: start a message to this number.
                    } label: {
                        Text(model.displayName(for: number) ?? " ")
                            .font(.body)
                            .foregroundStyle(IOSColor.iMessageBlue)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .frame(height: 90)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(key), spacing: gap * 1.45), count: 3), spacing: gap) {
                    ForEach(keys) { k in
                        Button {
                            if suppressTap { suppressTap = false; return }
                            if number.count < 32 { number.append(k.digit) }
                            Self.playTone(k.digit)
                        } label: {
                            VStack(spacing: -3) {
                                Text(k.digit).font(.system(size: key * 0.47, weight: .regular))
                                Text(k.letters).font(.system(size: 10, weight: .bold)).tracking(2).opacity(0.85).frame(height: 12)
                            }
                            .frame(width: key, height: key)
                            .foregroundStyle(.primary)
                            .contentShape(Circle())
                            .glassCircle()
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            guard k.digit == "0", number.count < 32 else { return }
                            suppressTap = true
                            number.append("+")
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        })
                    }
                }

                HStack(spacing: gap * 1.45) {
                    Group {
                        if model.sims.count > 1 || model.sipState == "ok" { SimPicker(subId: $subId, voip: $useVoip) } else { Color.clear }
                    }
                    .frame(width: key, height: key)

                    Button {
                        if useVoip && !AppModel.isUssd(number) { model.dialVoip(number) } else { model.dial(number, subId: subId) }
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: key * 0.38))
                            .foregroundStyle(.white)
                            .frame(width: key, height: key)
                            .background(IOSColor.callGreen.opacity(canCall ? 1 : 0.45), in: Circle())
                    }
                    .disabled(!canCall)

                    Button {
                        if suppressTap { suppressTap = false; return }
                        if !number.isEmpty { number.removeLast() }
                    } label: {
                        Image(systemName: "delete.left.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Color(uiColor: .systemGray2))
                            .frame(width: key, height: key)
                    }
                    .opacity(number.isEmpty ? 0 : 1)
                    .allowsHitTesting(!number.isEmpty)
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                        suppressTap = true
                        number = ""
                    })
                }

                Text(model.conn.isReady || useVoip ? " " : "Connect to the Android phone to call")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .sheet(isPresented: Binding(get: { model.ussd != nil }, set: { if !$0 { model.ussd = nil } })) {
            UssdSheet().environmentObject(model)
                .presentationDetents([.medium])
        }
    }

    /// The iPhone's own keypad tones (DTMF system sounds 1200–1211).
    static func playTone(_ key: String) {
        let ids: [String: SystemSoundID] = ["0": 1200, "1": 1201, "2": 1202, "3": 1203, "4": 1204, "5": 1205,
                                            "6": 1206, "7": 1207, "8": 1208, "9": 1209, "*": 1210, "#": 1211]
        if let id = ids[key] { AudioServicesPlaySystemSound(id) }
    }

    private var canCall: Bool {
        guard number.contains(where: { $0.isNumber }) else { return false }
        if useVoip { return model.sipState == "ok" }
        return model.conn.isReady && model.call.isIdle
    }
}

/// Carrier reply to a USSD code such as *140#.
struct UssdSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            switch model.ussd {
            case .running(let code):
                header(code)
                ProgressView().controlSize(.large).padding(.top, 20)
                Text("Waiting for the carrier…").foregroundStyle(.secondary)
            case .reply(let code, let text):
                header(code)
                ScrollView {
                    Text(text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .card()
            case .failed(let code, let msg):
                header(code)
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.fair)
                    .card()
            case .none:
                EmptyView()
            }
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .glass(in: Capsule(), tint: IOSColor.iMessageBlue, interactive: true)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .background(Theme.background.ignoresSafeArea())
    }

    private func header(_ code: String) -> some View {
        VStack(spacing: 4) {
            Text("Carrier Message").font(.headline)
            Text(code).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
