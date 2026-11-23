import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @State private var showCompose = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    if case .failed(let reason) = model.conn { offlineCard(reason) }
                    simSection
                    if let s = model.status { batteryCard(s) }
                    quickActions
                    if let s = model.status, s.perms.values.contains(false) { permsCard(s) }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .refreshable { model.sync(); model.reconnect() }
            .navigationTitle("SIMBridge")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showCompose) { ComposeView().environmentObject(model) }
        }
    }

    private var header: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.gradient)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.pairing?.name ?? "گوشی اندروید")
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                        if let d = model.status?.device {
                            Text("Android \(d.android)").font(.subheadline).opacity(0.85)
                        }
                    }
                    Spacer()
                    StatusPill(conn: model.conn).foregroundStyle(.primary)
                }
                HStack(spacing: 18) {
                    if let best = model.sims.first {
                        HStack(spacing: 8) {
                            Image(systemName: "cellularbars", variableValue: Double(best.inService ? best.level : 0) / 4.0)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(best.title).font(.subheadline.weight(.semibold))
                                Text(best.gen.isEmpty ? best.serviceText : best.gen).font(.caption).opacity(0.85)
                            }
                        }
                    }
                    if let b = model.status?.battery {
                        HStack(spacing: 6) {
                            Image(systemName: batteryIcon(b))
                            Text("\(b.level)٪").font(.subheadline.weight(.semibold))
                        }
                    }
                    Spacer()
                    if let ms = model.latencyMs {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.horizontal.fill")
                            Text("\(ms) ms").font(.caption.weight(.semibold))
                        }
                        .opacity(0.9)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(20)
        }
        .frame(minHeight: 150)
        .shadow(color: Theme.indigo.opacity(0.3), radius: 16, y: 8)
    }

    private func offlineCard(_ reason: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(Theme.fair)
            VStack(alignment: .leading, spacing: 2) {
                Text(reason).font(.subheadline.weight(.semibold))
                Text("هر دو گوشی باید روی یک Wi-Fi یا هات‌اسپات اندروید باشند و سرویس SIMBridge در اندروید روشن باشد.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("اتصال") { model.reconnect() }.buttonStyle(.borderedProminent).controlSize(.small)
        }
        .card()
    }

    private var simSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("آنتن و سیم‌کارت").font(.footnote.weight(.bold)).foregroundStyle(.secondary).padding(.leading, 4)
            if model.sims.isEmpty {
                HStack {
                    Image(systemName: "simcard").foregroundStyle(.secondary)
                    Text(model.conn.isReady ? "سیم‌کارتی گزارش نشده است" : "در انتظار اتصال…").foregroundStyle(.secondary)
                }
                .card()
            }
            ForEach(model.sims) { sim in
                SimCardView(sim: sim, multi: model.sims.count > 1)
            }
        }
    }

    private func batteryCard(_ s: PhoneStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: batteryIcon(s.battery))
                .font(.title2)
                .foregroundStyle(s.battery.level <= 15 && !s.battery.charging ? Theme.poor : Theme.good)
            VStack(alignment: .leading, spacing: 2) {
                Text("باتری اندروید: \(s.battery.level)٪").font(.subheadline.weight(.semibold))
                Text(s.battery.charging ? "در حال شارژ" : "بدون شارژر").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if s.airplane {
                Label("حالت پرواز", systemImage: "airplane").font(.caption.weight(.semibold)).foregroundStyle(Theme.fair)
            }
        }
        .card()
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            quick("پیام جدید", "square.and.pencil", Theme.indigo) { showCompose = true }
            quick("شماره‌گیر", "circle.grid.3x3.fill", Theme.good) { model.tab = .phone }
            quick("مخاطبین", "person.crop.circle", .orange) { model.tab = .contacts }
        }
    }

    private func quick(_ title: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2).foregroundStyle(color)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func permsCard(_ s: PhoneStatus) -> some View {
        let names = ["sms": "پیامک", "phone": "تماس و آنتن", "callLog": "تاریخچه تماس", "contacts": "مخاطبین"]
        let missing = s.perms.filter { !$0.value }.compactMap { names[$0.key] }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Theme.fair).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("دسترسی‌های ناقص در اندروید").font(.subheadline.weight(.semibold))
                Text("در اپ اندروید این دسترسی‌ها را بدهید: " + missing.joined(separator: "، "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
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
}

struct SimCardView: View {
    var sim: SimInfo
    var multi: Bool

    var body: some View {
        HStack(spacing: 16) {
            SignalBarsView(level: sim.level, inService: sim.inService, height: 34, barWidth: 8)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(sim.title).font(.headline)
                    if !sim.gen.isEmpty { tag(sim.gen, Theme.indigo) }
                    if sim.roaming { tag("رومینگ", Theme.fair) }
                }
                HStack(spacing: 6) {
                    if multi {
                        Text("سیم \(sim.slot + 1)")
                        Text("·")
                    }
                    Text(sim.serviceText)
                    if let dbm = sim.dbm { Text("·"); Text(Phone.ltr("\(dbm) dBm")) }
                    if !sim.net.isEmpty { Text("·"); Text(sim.net) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if multi {
                    let roles = [sim.smsSim ? "پیامک" : nil, sim.voiceSim ? "تماس" : nil, sim.dataSim ? "اینترنت" : nil].compactMap { $0 }
                    if !roles.isEmpty {
                        Text("پیش‌فرض: " + roles.joined(separator: "، ")).font(.caption2.weight(.semibold)).foregroundStyle(Theme.indigo)
                    }
                }
            }
            Spacer()
            qualityBadge
        }
        .card()
    }

    private var qualityBadge: some View {
        let (text, color): (String, Color) = {
            guard sim.inService else { return ("—", .gray) }
            switch sim.level {
            case 4: return ("عالی", Theme.good)
            case 3: return ("خوب", Theme.good)
            case 2: return ("متوسط", Theme.fair)
            case 1: return ("ضعیف", Theme.poor)
            default: return ("بدون آنتن", Theme.poor)
            }
        }()
        return Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.13), in: Capsule())
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.13), in: Capsule())
    }
}
