import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmUnpair = false
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            List {
                Section("گوشی اندروید") {
                    row("نام", model.pairing?.name ?? "—")
                    if let d = model.status?.device { row("نسخه اندروید", d.android) }
                    HStack {
                        Text("وضعیت")
                        Spacer()
                        StatusPill(conn: model.conn)
                    }
                    if let ms = model.latencyMs { row("تأخیر شبکه", "\(ms) ms") }
                    if let p = model.pairing {
                        row("آدرس‌ها", p.hosts.joined(separator: "، "), ltr: true)
                    }
                    Button("اتصال دوباره") { model.client.disconnect(); model.reconnect() }
                }

                Section {
                    HStack {
                        Label("اعلان‌ها", systemImage: "bell.badge.fill")
                        Spacer()
                        Text(notifText).foregroundStyle(notifStatus == .authorized ? Theme.good : Theme.fair)
                    }
                    if notifStatus != .authorized {
                        Button(notifStatus == .notDetermined ? "اجازه اعلان" : "باز کردن تنظیمات اعلان") {
                            if notifStatus == .notDetermined {
                                Notifier.requestAuthorization { _ in refreshNotif() }
                            } else if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    HStack {
                        Label("بیدارباش بلوتوث", systemImage: "dot.radiowaves.left.and.right")
                        Spacer()
                        Text(model.bleConnected ? "فعال" : "غیرفعال").foregroundStyle(model.bleConnected ? Theme.good : Theme.fair)
                    }
                } header: {
                    Text("اعلان در پس‌زمینه")
                } footer: {
                    Text("وقتی اپ بسته است، گوشی اندروید از طریق بلوتوث کم‌مصرف آیفون را بیدار می‌کند تا پیامک و تماس فوراً اعلان شوند. بلوتوث هر دو گوشی باید روشن باشد و نزدیک هم باشند. اپ را از صفحه چندوظیفگی ‌ نبندید (swipe up)، وگرنه iOS آن را بیدار نمی‌کند.")
                }

                Section {
                    Label("دیدن و پاسخ/رد تماس، شماره‌گیری، بلندگو و قطع صدا از آیفون", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                    Label("خودِ صدای مکالمه روی گوشی اندروید (یا هدست بلوتوثِ وصل به آن) است", systemImage: "info.circle.fill")
                        .foregroundStyle(.primary)
                } header: {
                    Text("درباره تماس صوتی")
                } footer: {
                    Text("اندروید به هیچ برنامه عادی اجازه دریافت یا ارسال صدای تماس سیم‌کارت را نمی‌دهد. برای شنیدن صدا روی آیفون باید از «انتقال تماس» اپراتور به یک سرویس VoIP یا درگاه سخت‌افزاری GSM/SIP استفاده شود.")
                }

                Section {
                    Button(role: .destructive) { confirmUnpair = true } label: {
                        Label("قطع جفت‌سازی و حذف اتصال", systemImage: "trash")
                    }
                } footer: {
                    Text("SIMBridge نسخه \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") · ارتباط مستقیم و رمزنگاری‌شده AES-256-GCM")
                }
            }
            .navigationTitle("تنظیمات")
            .onAppear { refreshNotif() }
            .confirmationDialog("اتصال با این گوشی اندروید حذف شود؟", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("حذف اتصال", role: .destructive) { model.unpair() }
                Button("انصراف", role: .cancel) {}
            } message: {
                Text("برای اتصال دوباره باید QR جدید اسکن کنید. در گوشی اندروید هم می‌توانید این آیفون را از فهرست حذف کنید.")
            }
        }
    }

    private var notifText: String {
        switch notifStatus {
        case .authorized, .provisional, .ephemeral: return "فعال"
        case .denied: return "خاموش"
        default: return "تعیین نشده"
        }
    }

    private func refreshNotif() { Notifier.authorizationStatus { notifStatus = $0 } }

    private func row(_ title: String, _ value: String, ltr: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(ltr ? Phone.ltr(value) : value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
