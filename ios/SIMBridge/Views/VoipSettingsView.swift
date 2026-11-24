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
                    Text("وضعیت")
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
                Text("وقتی خط وصل است و انتقال تماس روشن است، تماس‌های سیم‌کارت مثل یک تماس معمولی روی آیفون زنگ می‌خورد و با میکروفون و بلندگوی خود آیفون صحبت می‌کنید.")
            }

            Section("حساب SIP (از ارائه‌دهنده خط تلفن اینترنتی)") {
                field("سرور / دامنه", text: $acc.domain, placeholder: "sip.example.ir")
                field("نام کاربری", text: $acc.username, placeholder: "1001")
                SecureField("رمز عبور", text: $acc.password)
                    .textContentType(.password)
                Picker("پروتکل", selection: $acc.transport) {
                    Text("UDP").tag("udp")
                    Text("TCP").tag("tcp")
                    Text("TLS").tag("tls")
                }
                field("سرور خروجی (اختیاری)", text: $acc.proxy, placeholder: "خالی = همان دامنه")
                field("شماره تلفن این خط", text: $acc.lineNumber, placeholder: "021xxxxxxxx", keyboard: .phonePad)
            }

            Section {
                Button(model.sipAccount == nil ? "ذخیره و اتصال" : "ذخیره و اتصال دوباره") {
                    model.saveSipAccount(acc)
                }
                .disabled(!acc.isComplete)
                if model.sipAccount != nil {
                    Button("حذف خط", role: .destructive) {
                        model.saveSipAccount(nil)
                        acc = SipAccount()
                    }
                }
            }

            Section {
                if model.sims.isEmpty {
                    Text(model.conn.isReady ? "سیم‌کارتی گزارش نشده" : "برای انتقال تماس، به گوشی اندروید وصل شوید")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.sims) { sim in
                    forwardRow(sim)
                }
            } header: {
                Text("انتقال تماس‌های سیم‌کارت به این خط")
            } footer: {
                Text("«همه تماس‌ها»: هر تماسی به سیم، روی آیفون زنگ می‌خورد. «اگر جواب ندادم»: اول گوشی اندروید زنگ می‌خورد و اگر جواب داده نشد، مشغول بود یا در دسترس نبود به آیفون منتقل می‌شود. کد انتقال روی همان سیم زده می‌شود و تأیید اپراتور روی گوشی اندروید نمایش داده می‌شود. هزینه تماس‌های منتقل‌شده طبق تعرفه انتقال تماس اپراتور است.")
            }

            Section {
                Label("تماس‌های ورودی منتقل‌شده: صدای کامل دوطرفه روی آیفون", systemImage: "checkmark.circle.fill")
                Label("تماس خروجی از «خط اینترنتی» در صفحه‌کلید، با شماره همین خط گرفته می‌شود", systemImage: "info.circle.fill")
            }
            .font(.footnote)
        }
        .navigationTitle("خط تلفن اینترنتی")
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
                Text("سیم \(Fmt.persianDigits(String(sim.slot + 1))) · \(sim.title)")
                Text(modeText(mode)).font(.caption).foregroundStyle(mode == "off" ? Color.secondary : Theme.good)
            }
            Spacer()
            if busySub == sim.subId {
                ProgressView()
            } else {
                Menu {
                    Button("همه تماس‌ها به آیفون") { set(sim.subId, "all") }
                    Button("فقط اگر جواب ندادم / در دسترس نبودم") { set(sim.subId, "conditional") }
                    Button("خاموش (لغو انتقال)", role: .destructive) { set(sim.subId, "off") }
                } label: {
                    Text(mode == "off" ? "روشن کردن" : "تغییر").font(.subheadline.weight(.semibold))
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
        case "all": return "همه تماس‌ها به آیفون منتقل می‌شود"
        case "conditional": return "اگر جواب ندادم / در دسترس نبودم"
        default: return "خاموش"
        }
    }

    private var statusText: String {
        switch model.sipState {
        case "ok": return "وصل و آماده"
        case "registering": return "در حال اتصال…"
        case "failed": return "خطا در اتصال"
        default: return model.sipAccount == nil ? "تنظیم نشده" : "قطع"
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
