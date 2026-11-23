import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @State private var showCompose = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    statusCard
                    if case .failed = model.conn { offlineHint }
                    SectionHeader(title: "آنتن")
                    simCard
                    quickActions
                    if let s = model.status, s.perms.values.contains(false) { permsCard(s) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.background.ignoresSafeArea())
            .refreshable { model.sync(); model.reconnect() }
            .navigationTitle("SIMBridge")
            .sheet(isPresented: $showCompose) { ComposeView().environmentObject(model) }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconBadge(systemName: "iphone", tint: connColor, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.pairing?.name ?? "گوشی اندروید").font(.headline)
                    HStack(spacing: 6) {
                        Circle().fill(connColor).frame(width: 7, height: 7)
                        Text(connText).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let ms = model.latencyMs, model.conn.isReady {
                    Text(Phone.ltr("\(ms) ms"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let s = model.status {
                Divider().overlay(Theme.separator)
                HStack(spacing: 0) {
                    stat(icon: batteryIcon(s.battery), tint: batteryTint(s.battery),
                         value: Fmt.persianDigits("\(s.battery.level)") + "٪", label: s.battery.charging ? "در حال شارژ" : "باتری")
                    stat(icon: "simcard.2", tint: Theme.accent, value: Fmt.persianDigits("\(s.sims.count)"), label: "سیم‌کارت")
                    stat(icon: s.airplane ? "airplane" : "antenna.radiowaves.left.and.right",
                         tint: s.airplane ? Theme.fair : Theme.good,
                         value: s.airplane ? "روشن" : (bestSim?.gen.isEmpty == false ? bestSim!.gen : "—"),
                         label: s.airplane ? "حالت پرواز" : "شبکه")
                }
            }
        }
        .card()
    }

    private func stat(icon: String, tint: Color, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(.subheadline.weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var bestSim: SimInfo? { model.sims.first { $0.voiceSim } ?? model.sims.first }

    private var connColor: Color {
        switch model.conn {
        case .ready: return Theme.good
        case .connecting, .authenticating, .awaitingApproval: return Theme.fair
        default: return Theme.poor
        }
    }

    private var connText: String {
        switch model.conn {
        case .ready: return "متصل"
        case .connecting, .authenticating, .awaitingApproval: return "در حال اتصال…"
        case .idle: return "قطع"
        case .failed: return "در دسترس نیست"
        }
    }

    private var offlineHint: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemName: "wifi.exclamationmark", tint: Theme.fair)
            VStack(alignment: .leading, spacing: 6) {
                Text("هر دو گوشی باید روی یک Wi-Fi (یا هات‌اسپات اندروید) باشند و سرویس SIMBridge در اندروید روشن باشد.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("تلاش دوباره") { model.reconnect() }
                    .font(.footnote.weight(.semibold))
            }
        }
        .card(padding: 14)
    }

    // MARK: - SIMs

    private var simCard: some View {
        VStack(spacing: 0) {
            if model.sims.isEmpty {
                HStack(spacing: 12) {
                    IconBadge(systemName: "simcard", tint: Theme.muted)
                    Text(model.conn.isReady ? "سیم‌کارتی گزارش نشده است" : "در انتظار اتصال…")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            ForEach(Array(model.sims.enumerated()), id: \.element.id) { i, sim in
                if i > 0 { Divider().overlay(Theme.separator).padding(.leading, 50) }
                SimRow(sim: sim, multi: model.sims.count > 1)
            }
        }
        .card(padding: 14)
    }

    // MARK: - Actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            quick("پیام جدید", "square.and.pencil") { showCompose = true }
            quick("شماره‌گیر", "circle.grid.3x3") { model.tab = .phone }
            quick("مخاطبین", "person.crop.circle") { model.tab = .contacts }
        }
        .padding(.top, 4)
    }

    private func quick(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.accent)
                Text(title).font(.footnote.weight(.medium)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!model.conn.isReady)
        .opacity(model.conn.isReady ? 1 : 0.5)
    }

    private func permsCard(_ s: PhoneStatus) -> some View {
        let names = ["sms": "پیامک", "phone": "تماس و آنتن", "callLog": "تاریخچه تماس", "contacts": "مخاطبین"]
        let missing = s.perms.filter { !$0.value }.compactMap { names[$0.key] }.sorted()
        return HStack(alignment: .top, spacing: 12) {
            IconBadge(systemName: "exclamationmark.shield", tint: Theme.fair)
            VStack(alignment: .leading, spacing: 2) {
                Text("دسترسی ناقص در اندروید").font(.subheadline.weight(.semibold))
                Text("در اپ اندروید اجازه بدهید: " + missing.joined(separator: "، "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .card(padding: 14)
    }

    private func batteryIcon(_ b: BatteryInfo) -> String {
        if b.charging { return "battery.100.bolt" }
        switch b.level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private func batteryTint(_ b: BatteryInfo) -> Color {
        if b.charging { return Theme.good }
        return b.level <= 15 ? Theme.poor : Theme.good
    }
}

struct SimRow: View {
    var sim: SimInfo
    var multi: Bool

    var body: some View {
        HStack(spacing: 14) {
            SignalBarsView(level: sim.level, inService: sim.inService, height: 22, barWidth: 5)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(sim.title).font(.body.weight(.semibold))
                    if !sim.gen.isEmpty { Tag(text: sim.gen) }
                    if sim.roaming { Tag(text: "رومینگ", color: Theme.fair) }
                }
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text(quality.0)
                .font(.caption.weight(.semibold))
                .foregroundStyle(quality.1)
        }
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        var parts: [String] = []
        if multi { parts.append("سیم \(Fmt.persianDigits(String(sim.slot + 1)))") }
        parts.append(sim.serviceText)
        if let dbm = sim.dbm { parts.append(Phone.ltr("\(dbm) dBm") + "\u{200F}") }
        if multi {
            let roles = [sim.smsSim ? "پیامک" : nil, sim.voiceSim ? "تماس" : nil].compactMap { $0 }
            if !roles.isEmpty { parts.append("پیش‌فرض " + roles.joined(separator: " و ")) }
        }
        return parts.joined(separator: " · ")
    }

    private var quality: (String, Color) {
        guard sim.inService else { return ("—", Theme.muted) }
        switch sim.level {
        case 4: return ("عالی", Theme.good)
        case 3: return ("خوب", Theme.good)
        case 2: return ("متوسط", Theme.fair)
        case 1: return ("ضعیف", Theme.poor)
        default: return ("بدون آنتن", Theme.poor)
        }
    }
}
