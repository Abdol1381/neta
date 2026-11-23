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
                    Text("وقتی اپ در پس‌زمینه است، گوشی اندروید با بلوتوث کم‌مصرف آیفون را بیدار می‌کند تا پیامک و تماس فوراً اعلان شوند. بلوتوث هر دو گوشی روشن باشد و نزدیک هم باشند. اپ را از صفحه برنامه‌های باز با کشیدن به بالا نبندید؛ در آن حالت iOS آن را بیدار نمی‌کند.")
                }

                Section {
                    HStack {
                        Label("وضعیت در اندروید", systemImage: "ear")
                        Spacer()
                        Text(devAudioText).foregroundStyle(model.canListen ? Theme.good : Theme.fair)
                    }
                    Toggle("پخش خودکار هنگام مکالمه", isOn: $model.autoListen)
                        .disabled(!model.canListen)
                } header: {
                    Text("شنیدن تماس روی آیفون")
                } footer: {
                    Text("با حالت توسعه‌دهنده (اپ Shizuku، بدون روت) روی گوشی اندروید، صدای طرف مقابل روی آیفون یا AirPods پخش می‌شود، حتی با صفحه قفل. برای صحبت، با گوشی اندروید یا هدست بلوتوثِ وصل به آن صحبت کنید؛ اندروید اجازه نمی‌دهد صدای آیفون وارد تماس شود.")
                }

                Section {
                    Label("دیدن، پاسخ، رد و قطع تماس، شماره‌گیری با انتخاب سیم، بلندگو، بی‌صدا و کدهای USSD از آیفون", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                    Label("صحبت کردن با گوشی اندروید (یا هدست بلوتوثِ وصل به آن) انجام می‌شود", systemImage: "info.circle.fill")
                        .foregroundStyle(.primary)
                } header: {
                    Text("درباره تماس صوتی")
                } footer: {
                    Text("برای صدای کامل دوطرفه روی آیفون، درگاه سخت‌افزاری GSM لازم است.")
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

    private var devAudioText: String {
        switch model.status?.devAudio {
        case "ready": return "فعال"
        case "no_permission": return "اجازه Shizuku لازم است"
        case "no_shizuku": return "Shizuku فعال نیست"
        case "unsupported": return "پشتیبانی نمی‌شود"
        default: return model.conn.isReady ? "نامشخص" : "—"
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
