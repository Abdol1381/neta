import SwiftUI
import AudioToolbox

struct PhoneView: View {
    @EnvironmentObject var model: AppModel
    @State private var segment = TestHooks.phoneSegment

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text("صفحه‌کلید").tag(0)
                    Text("اخیر").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                if segment == 0 { KeypadView() } else { RecentsView() }
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationTitle("تلفن")
            .navigationBarTitleDisplayMode(.inline)
        }
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
            let key = min(78, max(56, (geo.size.height - 250) / 5.2))
            let gap = key * 0.24
            VStack(spacing: gap * 0.8) {
                Spacer(minLength: 4)
                VStack(spacing: 4) {
                    Text(number.isEmpty ? " " : number)
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity)
                        .ltr()
                    Text(model.displayName(for: number) ?? " ")
                        .font(.subheadline).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 24)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(key), spacing: gap * 1.3), count: 3), spacing: gap) {
                    ForEach(keys) { k in
                        Button {
                            if suppressTap { suppressTap = false; return }
                            if number.count < 32 { number.append(k.digit) }
                            Self.playTone(k.digit)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            VStack(spacing: -2) {
                                Text(k.digit).font(.system(size: key * 0.46, weight: .regular))
                                Text(k.letters).font(.system(size: 10, weight: .bold)).tracking(1.5).opacity(0.75).frame(height: 12)
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
                .ltr()

                HStack(spacing: gap * 1.3) {
                    Group {
                        if model.sims.count > 1 || model.sipState == "ok" { SimPicker(subId: $subId, voip: $useVoip) } else { Color.clear }
                    }
                    .frame(width: key, height: key)

                    Button {
                        if useVoip && !AppModel.isUssd(number) { model.dialVoip(number) } else { model.dial(number, subId: subId) }
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: key * 0.36))
                            .foregroundStyle(.white)
                            .frame(width: key, height: key)
                            .background(canCall ? IOSColor.callGreen : Color.gray.opacity(0.35), in: Circle())
                    }
                    .disabled(!canCall)

                    Button {
                        if suppressTap { suppressTap = false; return }
                        if !number.isEmpty { number.removeLast() }
                    } label: {
                        Image(systemName: "delete.left").font(.system(size: 24)).foregroundStyle(.secondary)
                            .frame(width: key, height: key)
                    }
                    .opacity(number.isEmpty ? 0 : 1)
                    .allowsHitTesting(!number.isEmpty)
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                        suppressTap = true
                        number = ""
                    })
                }
                .ltr()

                Text(model.conn.isReady ? " " : "برای تماس، اتصال به گوشی اندروید لازم است")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .sheet(isPresented: Binding(get: { model.ussd != nil }, set: { if !$0 { model.ussd = nil } })) {
            UssdSheet().environmentObject(model)
                .presentationDetents([.medium])
                .environment(\.layoutDirection, .rightToLeft)
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

struct RecentsView: View {
    @EnvironmentObject var model: AppModel
    @State private var missedOnly = false

    private var items: [CallLogEntry] {
        missedOnly ? model.recents.filter { $0.type == "missed" } : model.recents
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $missedOnly) {
                Text("همه").tag(false)
                Text("از دست رفته").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 60)
            .padding(.bottom, 6)
            if items.isEmpty {
                EmptyState(icon: "clock", title: missedOnly ? "تماس از دست رفته‌ای نیست" : "تماسی ثبت نشده",
                           subtitle: "تاریخچه تماس‌های سیم‌کارت اندروید اینجا نمایش داده می‌شود.")
            } else {
                List(items) { c in
                    Button {
                        model.dial(c.number)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: c.type == "out" ? "phone.arrow.up.right.fill" : "phone.arrow.down.left.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                                .opacity(c.type == "out" ? 1 : 0)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name.isEmpty ? Phone.ltr(c.title) : c.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(c.type == "missed" || c.type == "rejected" ? IOSColor.callRed : .primary)
                                    .lineLimit(1)
                                Text(label(c)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Fmt.short(c.date)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(c.number.isEmpty || !model.conn.isReady)
                }
                .listStyle(.plain)
                .minimizingTabBar()
            }
        }
        .refreshable { model.loadRecents() }
        .onAppear { model.loadRecents() }
    }

    private func label(_ c: CallLogEntry) -> String {
        let kind: String
        switch c.type {
        case "in": kind = "ورودی"
        case "out": kind = "خروجی"
        case "missed": kind = "از دست رفته"
        case "rejected": kind = "رد شده"
        case "blocked": kind = "مسدود"
        default: kind = "تماس"
        }
        return c.duration > 0 ? "\(kind) · \(Fmt.duration(c.duration))" : kind
    }
}

/// Operator reply to a USSD code such as *140#.
struct UssdSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 36, height: 5).padding(.top, 8)
            switch model.ussd {
            case .running(let code):
                header(code)
                ProgressView().controlSize(.large).padding(.top, 20)
                Text("در انتظار پاسخ اپراتور…").foregroundStyle(.secondary)
            case .reply(let code, let text):
                header(code)
                ScrollView {
                    Text(text)
                        .font(.body)
                        .multilineTextAlignment(.leading)
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
            Button("بستن") { dismiss() }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(Theme.background.ignoresSafeArea())
    }

    private func header(_ code: String) -> some View {
        VStack(spacing: 4) {
            Text("پاسخ اپراتور").font(.headline)
            Text(Phone.ltr(code)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
