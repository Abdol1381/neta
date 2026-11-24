import SwiftUI
import UserNotifications
import Contacts

/// Settings in the style of the iPhone's Settings app: the Android phone card on top
/// (like the Apple Account row), then grouped rows with coloured icon tiles.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmUnpair = false
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var contactsStatus: CNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { PhoneStatusView() } label: { phoneCard }
                }

                if let s = model.status {
                    Section {
                        ForEach(s.sims) { sim in SimRow(sim: sim, multi: s.sims.count > 1) }
                    } header: {
                        Text("Cellular")
                    }
                }

                Section {
                    NavigationLink { VoipSettingsView() } label: {
                        SettingsRow(icon: "phone.connection.fill", color: .green, title: "Internet Phone Line", value: sipText)
                    }
                    Toggle(isOn: $model.useCallKit) {
                        SettingsRow(icon: "phone.bubble.fill", color: .green, title: "Ring with iPhone Call Screen")
                    }
                    NavigationLink { HearCallsView() } label: {
                        SettingsRow(icon: "ear.fill", color: .orange, title: "Hear Calls on iPhone", value: devAudioText)
                    }
                } header: {
                    Text("Calls")
                } footer: {
                    Text("Incoming SIM calls ring with the iPhone's own call screen, even when locked. For full two-way voice on the iPhone, forward calls to an internet phone line.")
                }

                Section {
                    HStack {
                        SettingsRow(icon: "bell.badge.fill", color: .red, title: "Notifications", value: notifText)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { openNotificationSettings() }
                    HStack {
                        SettingsRow(icon: "person.crop.circle.fill", color: .gray, title: "Caller ID from iPhone Contacts", value: contactsText)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { requestContacts() }
                    Toggle(isOn: $model.keepConnected) {
                        SettingsRow(icon: "link", color: .blue, title: "Stay Connected in Background")
                    }
                    HStack {
                        SettingsRow(icon: "dot.radiowaves.left.and.right", color: .blue, title: "Bluetooth Wake",
                                    value: model.bleConnected ? "On" : "Off")
                    }
                } header: {
                    Text("Background")
                } footer: {
                    Text("Stay Connected keeps the link open in the background so calls and messages arrive instantly (an inaudible sound that never interrupts other audio; uses a little battery). Don't swipe SIMBridge away in the App Switcher, or iOS can't wake it.")
                }

                Section {
                    NavigationLink { DiagnosticsView() } label: {
                        SettingsRow(icon: "stethoscope", color: .gray, title: "Diagnostics")
                    }
                } footer: {
                    Text("If calls, audio or the connection misbehave, share this report.")
                }

                Section {
                    Button(role: .destructive) { confirmUnpair = true } label: {
                        Text("Unpair Android Phone")
                    }
                } footer: {
                    Text("SIMBridge \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") · Direct, end-to-end encrypted (AES-256-GCM). Nothing goes through a server.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .onAppear {
                refreshNotif()
                contactsStatus = model.iphoneContacts.status
            }
            .confirmationDialog("Unpair this Android phone?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { model.unpair() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to scan a new QR code to connect again.")
            }
        }
    }

    /// Like the Apple Account row at the top of iPhone Settings.
    private var phoneCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(red: 0.36, green: 0.82, blue: 0.45), Color(red: 0.16, green: 0.62, blue: 0.30)],
                                             startPoint: .top, endPoint: .bottom))
                Image(systemName: "candybarphone").font(.system(size: 26, weight: .medium)).foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.pairing?.name ?? "Android Phone").font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(connColor).frame(width: 7, height: 7)
                    Text(connSubtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var connColor: Color {
        switch model.conn {
        case .ready: return Theme.good
        case .connecting, .authenticating, .awaitingApproval: return Theme.fair
        default: return Theme.poor
        }
    }

    private var connSubtitle: String {
        var parts: [String] = []
        switch model.conn {
        case .ready: parts.append("Connected")
        case .connecting, .authenticating, .awaitingApproval: parts.append("Connecting…")
        case .idle: parts.append("Disconnected")
        case .failed: parts.append("Unavailable")
        }
        if let b = model.status?.battery { parts.append("\(b.level)%" + (b.charging ? " ⚡︎" : "")) }
        return parts.joined(separator: " · ")
    }

    private var sipText: String {
        switch model.sipState {
        case "ok": return "Connected"
        case "registering": return "Connecting…"
        case "failed": return "Error"
        default: return model.sipAccount == nil ? "Off" : "Disconnected"
        }
    }

    private var contactsText: String {
        if model.iphoneContacts.authorized { return "On" }
        switch contactsStatus {
        case .denied, .restricted: return "Not Allowed"
        default: return "Off"
        }
    }

    private var devAudioText: String {
        switch model.status?.devAudio {
        case "ready": return "On"
        case "no_permission": return "Allow in Shizuku"
        case "no_shizuku", "not_set_up": return "Not Set Up"
        case "adb_offline": return "Offline"
        case "unsupported": return "Not Supported"
        default: return model.conn.isReady ? "—" : "—"
        }
    }

    private var notifText: String {
        switch notifStatus {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Off"
        default: return "Not Set"
        }
    }

    private func refreshNotif() { Notifier.authorizationStatus { notifStatus = $0 } }

    private func openNotificationSettings() {
        if notifStatus == .notDetermined {
            Notifier.requestAuthorization { _ in refreshNotif() }
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func requestContacts() {
        if contactsStatus == .notDetermined {
            model.iphoneContacts.requestAccess { _ in contactsStatus = model.iphoneContacts.status }
        } else if !model.iphoneContacts.authorized, let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// A Settings row with the iOS coloured rounded-square icon, title and trailing value.
struct SettingsRow: View {
    var icon: String
    var color: Color
    var title: String
    var value: String? = nil
    /// Icon tiles grow with the text size, like in the Settings app.
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 29
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 15

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: tile, height: tile)
                .background(color, in: RoundedRectangle(cornerRadius: tile * 0.24, style: .continuous))
            Text(title).foregroundStyle(.primary).layoutPriority(1)
            Spacer(minLength: 8)
            if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// "Hear Calls on iPhone" detail page.
struct HearCallsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Status on Android")
                    Spacer()
                    Text(model.canListen ? "Ready" : "Not Ready").foregroundStyle(model.canListen ? Theme.good : Theme.fair)
                }
                if model.status?.lockSecure == true {
                    Label("The Android phone has a PIN/pattern screen lock. On Android 11, call audio can only start while it's unlocked — set its screen lock to None or Swipe (Settings → Security → Screen lock).",
                          systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.fair)
                }
            } footer: {
                Text("After a one-time setup in the Android app (“شنیدن تماس روی آیفون” → “راه‌اندازی”, no root needed), the other person's voice plays on this iPhone or AirPods, even when locked. You still speak into the Android phone or a headset paired with it — Android doesn't let the iPhone's voice into a SIM call. For full two-way voice, use an Internet Phone Line.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Hear Calls on iPhone")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Android phone details (signal, battery, connection) — opened from the card at the top of Settings.
struct PhoneStatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                row("Name", model.pairing?.name ?? "—")
                if let d = model.status?.device { row("Android Version", d.android) }
                row("Status", statusText)
                if let ms = model.latencyMs { row("Latency", "\(ms) ms") }
                if let b = model.status?.battery { row("Battery", "\(b.level)%" + (b.charging ? " · Charging" : "")) }
                if model.status?.airplane == true { row("Airplane Mode", "On") }
            }
            if let s = model.status, !s.sims.isEmpty {
                Section("SIM Cards") {
                    ForEach(s.sims) { sim in
                        VStack(alignment: .leading, spacing: 6) {
                            SimRow(sim: sim, multi: s.sims.count > 1)
                            if !sim.number.isEmpty { Text(sim.number).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if let p = model.pairing {
                Section {
                    row("Addresses", p.hosts.joined(separator: ", "))
                    Button("Reconnect") { model.client.disconnect(); model.reconnect() }
                } header: {
                    Text("Network")
                } footer: {
                    Text("Both phones must be on the same Wi-Fi, or the iPhone joined to the Android phone's hotspot.")
                }
            }
            if let s = model.status, s.perms.values.contains(false) {
                Section {
                    Text("Some permissions are missing in the Android app: " +
                         s.perms.filter { !$0.value }.map(\.key).sorted().joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(Theme.fair)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(model.pairing?.name ?? "Android Phone")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { model.sync() }
    }

    private var statusText: String {
        switch model.conn {
        case .ready: return "Connected"
        case .connecting, .authenticating, .awaitingApproval: return "Connecting…"
        case .idle: return "Disconnected"
        case .failed(let r): return r
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

/// Settings → Diagnostics: recent events from this iPhone and from the Android phone.
struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @State private var androidLog = ""
    @State private var loading = false

    private var report: String {
        var r = "SIMBridge diagnostics — \(Date())\n"
        r += "iOS \(UIDevice.current.systemVersion) · link \(model.conn) · keepConnected \(model.keepConnected) · keeper \(model.keeper.isRunning)\n"
        r += "devAudio \(model.status?.devAudio ?? "-") · lockSecure \(model.status?.lockSecure ?? false) · sip \(model.sipState)\n\n"
        r += "== iPhone ==\n" + DiagLog.text + "\n\n== Android ==\n" + (androidLog.isEmpty ? "(not loaded)" : androidLog)
        return r
    }

    var body: some View {
        List {
            Section {
                ShareLink(item: report) { Label("Share Report", systemImage: "square.and.arrow.up") }
                Button { UIPasteboard.general.string = report } label: { Label("Copy Report", systemImage: "doc.on.doc") }
                Button { loadAndroid() } label: {
                    HStack {
                        Label("Reload Android Log", systemImage: "arrow.clockwise")
                        if loading { Spacer(); ProgressView() }
                    }
                }
            }
            Section("iPhone") {
                Text(DiagLog.text.isEmpty ? "No events yet" : DiagLog.text)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("Android") {
                Text(androidLog.isEmpty ? (model.conn.isReady ? "Loading…" : "Not connected") : androidLog)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadAndroid() }
    }

    private func loadAndroid() {
        loading = true
        model.client.request("diag", timeout: 10) { r in
            loading = false
            if case .success(let d) = r { androidLog = d["text"] as? String ?? "" }
        }
    }
}
