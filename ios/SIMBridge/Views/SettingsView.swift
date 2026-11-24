import SwiftUI
import UserNotifications
import Contacts

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmUnpair = false
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var contactsStatus: CNAuthorizationStatus = .notDetermined

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
                    NavigationLink {
                        VoipSettingsView()
                    } label: {
                        HStack {
                            Label("خط تلفن اینترنتی", systemImage: "phone.connection")
                            Spacer()
                            Text(sipText).foregroundStyle(model.sipState == "ok" ? Theme.good : .secondary)
                        }
                    }
                } footer: {
                    Text("برای صحبت کامل دوطرفه روی آیفون: تماس‌های سیم‌کارت به یک خط تلفن اینترنتی منتقل می‌شوند و همین‌جا جواب داده می‌شوند.")
                }

                Section {
                    HStack {
                        Label("مخاطبین آیفون", systemImage: "person.crop.circle.badge.checkmark")
                        Spacer()
                        Text(contactsText).foregroundStyle(model.iphoneContacts.authorized ? Theme.good : Theme.fair)
                    }
                    if !model.iphoneContacts.authorized {
                        Button(contactsStatus == .notDetermined ? "اجازه دسترسی به مخاطبین" : "باز کردن تنظیمات") {
                            if contactsStatus == .notDetermined {
                                model.iphoneContacts.requestAccess { _ in contactsStatus = model.iphoneContacts.status }
                            } else if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } header: {
                    Text("شناسایی تماس‌گیرنده")
                } footer: {
                    Text("نام تماس‌گیرنده و فرستنده پیامک از مخاطبین آیفون و گوشی اندروید شناسایی می‌شود (اولویت با آیفون). مخاطبین از آیفون خارج نمی‌شوند.")
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
                    Toggle(isOn: $model.keepConnected) {
                        Label("همیشه متصل در پس‌زمینه", systemImage: "link")
                    }
                    HStack {
                        Label("بیدارباش بلوتوث", systemImage: "dot.radiowaves.left.and.right")
                        Spacer()
                        Text(model.bleConnected ? "فعال" : "غیرفعال").foregroundStyle(model.bleConnected ? Theme.good : Theme.fair)
                    }
                } header: {
                    Text("اعلان در پس‌زمینه")
                } footer: {
                    Text("«همیشه متصل»: اپ در پس‌زمینه هم وصل می‌ماند تا تماس و پیامک فوراً برسد (با پخش یک صدای بی‌صدا که صدای دیگر برنامه‌ها را قطع نمی‌کند؛ کمی باتری مصرف می‌کند). اگر خاموش باشد، گوشی اندروید با بلوتوث کم‌مصرف آیفون را بیدار می‌کند تا پیامک و تماس فوراً اعلان شوند. بلوتوث هر دو گوشی روشن باشد و نزدیک هم باشند. اپ را از صفحه برنامه‌های باز با کشیدن به بالا نبندید؛ در آن حالت iOS آن را بیدار نمی‌کند.")
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
                    Text("با راه‌اندازی یک‌باره «شنیدن تماس» در اپ اندروید (بدون روت)، صدای طرف مقابل روی آیفون یا AirPods پخش می‌شود، حتی با صفحه قفل. برای صحبت، با گوشی اندروید یا هدست بلوتوثِ وصل به آن صحبت کنید؛ اندروید اجازه نمی‌دهد صدای آیفون وارد تماس شود.")
                }

                Section {
                    Toggle(isOn: $model.useCallKit) {
                        Label("زنگ با صفحه تماس آیفون", systemImage: "phone.bubble.left")
                    }
                    Label("دیدن، پاسخ، رد و قطع تماس، شماره‌گیری با انتخاب سیم، بلندگو، بی‌صدا و کدهای USSD از آیفون", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                    Label("صحبت کردن با گوشی اندروید (یا هدست بلوتوثِ وصل به آن) انجام می‌شود", systemImage: "info.circle.fill")
                        .foregroundStyle(.primary)
                } header: {
                    Text("درباره تماس صوتی")
                } footer: {
                    Text("با «زنگ با صفحه تماس آیفون»، تماس ورودی مثل یک تماس واقعی تمام‌صفحه زنگ می‌خورد (حتی روی صفحه قفل) و پاسخ، رد، قطع و بی‌صدا از همان صفحه کار می‌کند. برای صدای کامل دوطرفه روی آیفون، انتقال تماس به خط اینترنتی یا درگاه GSM لازم است.")
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
            .onAppear {
                refreshNotif()
                contactsStatus = model.iphoneContacts.status
            }
            .confirmationDialog("اتصال با این گوشی اندروید حذف شود؟", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("حذف اتصال", role: .destructive) { model.unpair() }
                Button("انصراف", role: .cancel) {}
            } message: {
                Text("برای اتصال دوباره باید QR جدید اسکن کنید. در گوشی اندروید هم می‌توانید این آیفون را از فهرست حذف کنید.")
            }
        }
    }

    private var sipText: String {
        switch model.sipState {
        case "ok": return "وصل"
        case "registering": return "در حال اتصال…"
        case "failed": return "خطا"
        default: return model.sipAccount == nil ? "تنظیم نشده" : "قطع"
        }
    }

    private var contactsText: String {
        if model.iphoneContacts.authorized {
            return "\(Fmt.persianDigits(String(model.iphoneContacts.list.count))) مخاطب"
        }
        switch contactsStatus {
        case .denied, .restricted: return "اجازه داده نشده"
        default: return "تعیین نشده"
        }
    }

    private var devAudioText: String {
        switch model.status?.devAudio {
        case "ready": return "فعال"
        case "no_permission": return "اجازه Shizuku لازم است"
        case "no_shizuku", "not_set_up": return "راه‌اندازی نشده"
        case "adb_offline": return "اشکال‌زدایی بی‌سیم وصل نیست"
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
