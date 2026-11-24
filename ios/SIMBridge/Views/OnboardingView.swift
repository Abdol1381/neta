import SwiftUI

/// Welcome / pairing, styled like Apple's own setup screens ("What's New" layout).
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var showScanner = false
    @State private var showManual = false
    @State private var manualText = ""
    @State private var cameraDenied = false
    @State private var invalidCode = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 30) {
                        header
                        if model.pairingStage == .idle {
                            features
                        } else {
                            PairingProgressCard()
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 50)
                    .padding(.bottom, 20)
                }
                if model.pairingStage == .idle { bottom }
            }
        }
        .sheet(isPresented: $showScanner) { scannerSheet }
        .onAppear { LocalNetwork.requestPermission() }
        .alert("Invalid Code", isPresented: $invalidCode) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This QR code isn't from SIMBridge or is incomplete.")
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.82, blue: 0.45), Color(red: 0.16, green: 0.62, blue: 0.30)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 84, height: 84)
                Image(systemName: "simcard.fill").font(.system(size: 38, weight: .semibold)).foregroundStyle(.white)
            }
            Text("Welcome to SIMBridge")
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 26) {
            feature("message.fill", .green, "Messages",
                    "Send and receive texts from your Android phone's SIM, right here.")
            feature("phone.fill", .green, "Calls",
                    "Incoming calls ring on your iPhone's call screen. Answer, decline and dial from the iPhone.")
            feature("antenna.radiowaves.left.and.right", .blue, "Signal & SIMs",
                    "See live signal for each SIM, carrier codes like *140#, and the phone's battery.")
            feature("lock.fill", .gray, "Private",
                    "A direct, end-to-end encrypted link between your two phones. No servers.")
        }
    }

    private func feature(_ icon: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(color)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bottom: some View {
        VStack(spacing: 14) {
            Text("On the Android phone, open SIMBridge and tap “اتصال آیفون” (Connect iPhone). Both phones must be on the same Wi-Fi, or the iPhone on the Android hotspot.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showScanner = true
            } label: {
                Text("Scan QR Code")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundStyle(.white)
                    .glass(in: Capsule(), tint: IOSColor.iMessageBlue, interactive: true)
            }
            .buttonStyle(.plain)
            Button("Enter Link Manually") { withAnimation { showManual.toggle() } }
                .font(.subheadline)
            if showManual {
                HStack {
                    TextField("simbridge://pair?…", text: $manualText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    Button("Connect") { submit(manualText) }
                        .disabled(manualText.isEmpty)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private var scannerSheet: some View {
        ZStack {
            if cameraDenied {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Camera Access Needed").font(.headline)
                    Text("Allow camera access for SIMBridge in Settings, or enter the link manually.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.borderedProminent)
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
                    Text("Point at the QR code on the Android phone")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .glassCapsule()
                        .padding(.bottom, 40)
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button { showScanner = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(cameraDenied ? Color.primary : Color.white)
                            .frame(width: 40, height: 40)
                            .glassCircle()
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
                Text("Connecting to Android Phone…").font(.headline)
                Text("If this takes a while, check that both phones are on the same network.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .confirm(let code):
                Text("Verification Code").font(.headline)
                Text(code.map(String.init).joined(separator: " "))
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Confirm on the Android phone if it shows the same code.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ProgressView()
            case .success:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundStyle(Theme.good)
                Text("Connected").font(.title2.bold())
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(Theme.fair)
                Text("Couldn't Connect").font(.headline)
                Text(reason).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if model.pairingStage != .success {
                Button(isFailed ? "Try Again" : "Cancel") { model.cancelPairing() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeInOut, value: model.pairingStage)
    }

    private var isFailed: Bool {
        if case .failed = model.pairingStage { return true }
        return false
    }
}
