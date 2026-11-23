import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var showScanner = false
    @State private var showManual = false
    @State private var manualText = ""
    @State private var cameraDenied = false
    @State private var invalidCode = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    hero
                    if model.pairingStage == .idle {
                        steps
                        actions
                    } else {
                        PairingProgressCard()
                    }
                    Text("هیچ داده‌ای به سرور یا شخص ثالث ارسال نمی‌شود؛ ارتباط مستقیم و رمزنگاری‌شده بین دو گوشی شماست.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(20)
            }
        }
        .sheet(isPresented: $showScanner) { scannerSheet }
        .alert("کد معتبر نیست", isPresented: $invalidCode) {
            Button("باشه", role: .cancel) {}
        } message: {
            Text("این QR متعلق به SIMBridge نیست یا ناقص است.")
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.gradient)
                    .frame(width: 96, height: 96)
                    .shadow(color: Theme.indigo.opacity(0.35), radius: 18, y: 8)
                Image(systemName: "simcard.fill").font(.system(size: 44, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.top, 30)
            Text("SIMBridge").font(.system(size: 34, weight: .black, design: .rounded))
            Text("پیامک، تماس و آنتنِ سیم‌کارتِ گوشی اندرویدی‌تان، روی آیفون")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            step(1, "اپ SIMBridge را روی گوشی اندروید نصب و دسترسی‌ها را تأیید کنید.", "iphone")
            step(2, "هر دو گوشی را به یک Wi-Fi وصل کنید، یا آیفون را به هات‌اسپات گوشی اندروید.", "wifi")
            step(3, "در اندروید «اتصال آیفون جدید» را بزنید و QR را با دکمه زیر اسکن کنید.", "qrcode.viewfinder")
        }
        .card()
    }

    private func step(_ n: Int, _ text: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Theme.indigo.opacity(0.12)).frame(width: 40, height: 40)
                Image(systemName: icon).foregroundStyle(Theme.indigo)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("مرحله \(n)").font(.caption.weight(.bold)).foregroundStyle(Theme.indigo)
                Text(text).font(.subheadline)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                showScanner = true
            } label: {
                Label("اسکن QR", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(.white)
            }
            Button("وارد کردن دستی لینک اتصال") { showManual.toggle() }
                .font(.subheadline)
            if showManual {
                VStack(spacing: 10) {
                    TextField("simbridge://pair?…", text: $manualText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                        .padding(12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                        .ltr()
                    Button("اتصال") { submit(manualText) }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualText.isEmpty)
                }
            }
        }
    }

    private var scannerSheet: some View {
        ZStack {
            if cameraDenied {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.secondary)
                    Text("دسترسی دوربین داده نشده است").font(.headline)
                    Text("از تنظیمات آیفون، دسترسی دوربین را برای SIMBridge روشن کنید یا لینک اتصال را دستی وارد کنید.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("باز کردن تنظیمات") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.buttonStyle(.borderedProminent)
                }
                .padding(30)
            } else {
                ScannerView(onCode: { code in
                    showScanner = false
                    submit(code)
                }, onDenied: { cameraDenied = true })
                .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 4)
                    .frame(width: 250, height: 250)
                VStack {
                    Spacer()
                    Text("QR نمایش‌داده‌شده در اپ اندروید را در کادر قرار دهید")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 40)
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button { showScanner = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 30)).symbolRenderingMode(.hierarchical)
                            .foregroundStyle(cameraDenied ? Color.secondary : Color.white)
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }

    private func submit(_ code: String) {
        if !model.startPairing(with: code) { invalidCode = true }
    }
}

struct PairingProgressCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            switch model.pairingStage {
            case .connecting, .idle:
                ProgressView().controlSize(.large)
                Text("در حال اتصال به گوشی اندروید…").font(.headline)
                Text("اگر طول کشید، مطمئن شوید هر دو گوشی روی یک شبکه هستند.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .confirm(let code):
                Image(systemName: "checkmark.shield.fill").font(.system(size: 40)).foregroundStyle(Theme.indigo)
                Text("کد تأیید").font(.headline)
                Text(code.map(String.init).joined(separator: " "))
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.indigo)
                    .ltr()
                Text("روی گوشی اندروید همین کد نمایش داده می‌شود. اگر یکی است، آنجا «تأیید و اتصال» را بزنید.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ProgressView()
            case .success:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.good)
                Text("اتصال برقرار شد").font(.title3.bold())
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(Theme.fair)
                Text("اتصال انجام نشد").font(.headline)
                Text(reason).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if model.pairingStage != .success {
                Button(isFailed ? "تلاش دوباره" : "انصراف") { model.cancelPairing() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .card()
        .animation(.easeInOut, value: model.pairingStage)
    }

    private var isFailed: Bool {
        if case .failed = model.pairingStage { return true }
        return false
    }
}
