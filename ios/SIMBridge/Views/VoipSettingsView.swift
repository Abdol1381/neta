import SwiftUI

/// Internet phone line (SIP) + forwarding the SIM's calls to it, so calls ring on the iPhone with
/// real two-way audio.
struct VoipSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var acc = SipAccount()
    @State private var loaded = false
    @State private var busySub: Int?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText).foregroundStyle(.secondary)
                    }
                }
                if model.sipState == "failed", !model.sipMessage.isEmpty {
                    Text(model.sipMessage).font(.footnote).foregroundStyle(Theme.poor)
                }
            } footer: {
                Text("When the line is connected and forwarding is on, SIM calls ring on this iPhone like a normal call and you talk using the iPhone's own microphone and speaker.")
            }

            Section("SIP Account (from your internet phone provider)") {
                field("Server", text: $acc.domain, placeholder: "sip.example.com")
                field("User Name", text: $acc.username, placeholder: "1001")
                SecureField("Password", text: $acc.password)
                    .textContentType(.password)
                Picker("Transport", selection: $acc.transport) {
                    Text("UDP").tag("udp")
                    Text("TCP").tag("tcp")
                    Text("TLS").tag("tls")
                }
                field("Outbound Proxy", text: $acc.proxy, placeholder: "Optional")
                field("Line Number", text: $acc.lineNumber, placeholder: "021xxxxxxxx", keyboard: .phonePad)
            }

            Section {
                Button(model.sipAccount == nil ? "Save & Connect" : "Save & Reconnect") {
                    model.saveSipAccount(acc)
                }
                .disabled(!acc.isComplete)
                if model.sipAccount != nil {
                    Button("Remove Line", role: .destructive) {
                        model.saveSipAccount(nil)
                        acc = SipAccount()
                    }
                }
            }

            Section {
                if model.sims.isEmpty {
                    Text(model.conn.isReady ? "No SIM reported" : "Connect to the Android phone to set forwarding")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.sims) { sim in
                    forwardRow(sim)
                }
            } header: {
                Text("Forward SIM Calls to This Line")
            } footer: {
                Text("All Calls: every call to the SIM rings on this iPhone. When Unanswered: the Android phone rings first, then calls move here if unanswered, busy or unreachable. The carrier confirms on the Android phone. Forwarded minutes are charged at the carrier's forwarding rate.")
            }

            Section {
                Label("Forwarded calls: full two-way audio on the iPhone", systemImage: "checkmark.circle.fill")
                Label("Calls from the keypad via “Internet Line” show this line's number", systemImage: "info.circle.fill")
            }
            .font(.footnote)
        }
        .navigationTitle("Internet Phone Line")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !loaded {
                acc = model.sipAccount ?? SipAccount()
                loaded = true
            }
        }
    }

    private func forwardRow(_ sim: SimInfo) -> some View {
        let key = String(sim.subId)
        let mode = model.forwarding[key] ?? "off"
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SIM \(sim.slot + 1) · \(sim.title)")
                Text(modeText(mode)).font(.caption).foregroundStyle(mode == "off" ? Color.secondary : Theme.good)
            }
            Spacer()
            if busySub == sim.subId {
                ProgressView()
            } else {
                Menu {
                    Button("All Calls") { set(sim.subId, "all") }
                    Button("When Unanswered / Unreachable") { set(sim.subId, "conditional") }
                    Button("Off", role: .destructive) { set(sim.subId, "off") }
                } label: {
                    Text(mode == "off" ? "Turn On" : "Change").font(.subheadline.weight(.semibold))
                }
                .disabled(!model.conn.isReady)
            }
        }
    }

    private func set(_ subId: Int, _ mode: String) {
        busySub = subId
        model.setForwarding(subId: subId, mode: mode) { _ in busySub = nil }
    }

    private func modeText(_ m: String) -> String {
        switch m {
        case "all": return "All calls forwarded"
        case "conditional": return "When unanswered"
        default: return "Off"
        }
    }

    private var statusText: String {
        switch model.sipState {
        case "ok": return "Connected"
        case "registering": return "Connecting…"
        case "failed": return "Can't Connect"
        default: return model.sipAccount == nil ? "Not Set Up" : "Disconnected"
        }
    }

    private var statusColor: Color {
        switch model.sipState {
        case "ok": return Theme.good
        case "registering": return Theme.fair
        case "failed": return Theme.poor
        default: return Theme.muted
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType = .default) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .ltr()
        }
    }
}
