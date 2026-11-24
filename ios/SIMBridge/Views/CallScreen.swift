import SwiftUI

/// In-app call screen in the style of the iPhone's own call UI (iOS 26 Liquid Glass controls).
struct CallScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var now = Date()
    @State private var busy = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var call: CallInfo { model.call }
    private var ringing: Bool { call.state == "ringing" }
    private var title: String {
        call.name.isEmpty ? (call.number.isEmpty ? "Unknown" : call.number) : call.name
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                HStack {
                    Button { model.callScreenMinimized = true } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .glassCircle()
                    }
                    Spacer()
                    if let sim = model.sim(for: call.subId) {
                        HStack(spacing: 6) {
                            SignalBarsView(level: sim.level, inService: sim.inService, height: 12, barWidth: 3.5)
                            Text(model.sims.count > 1 ? "SIM \(sim.slot + 1) · \(sim.title)" : sim.title)
                                .font(.footnote.weight(.semibold))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .glassCapsule()
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, 8)

                // Name block at the top, like the iOS call screen.
                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    Text(statusLine)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                    if !call.name.isEmpty && !call.number.isEmpty {
                        Text(call.number).font(.subheadline).foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 36)

                Spacer()

                if !ringing {
                    Label(audioHint, systemImage: model.listening ? "ear" : "iphone.radiowaves.left.and.right")
                        .multilineTextAlignment(.center)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassCapsule()
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)
                }

                if ringing { ringingControls } else { activeControls }
            }
            .padding(.bottom, 34)
        }
        .onReceive(timer) { now = $0 }
        .preferredColorScheme(.dark)
    }

    /// Soft dark gradient with a blurred monogram glow (contact-poster feel).
    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.16), Color(red: 0.04, green: 0.04, blue: 0.07)],
                           startPoint: .top, endPoint: .bottom)
            Avatar(name: call.name.isEmpty ? call.number : call.name, size: 420)
                .blur(radius: 90)
                .opacity(0.45)
                .offset(y: -160)
        }
        .ignoresSafeArea()
    }

    private var audioHint: String {
        if model.listening { return "Hearing the call on iPhone · speak into the Android phone or its headset" }
        return "Call audio is on the Android phone"
    }

    private var statusLine: String {
        switch call.state {
        case "ringing": return "incoming call…"
        case "offhook":
            guard call.since > 0 else { return call.direction == "out" ? "calling…" : "connecting…" }
            return Fmt.duration(Int64(now.timeIntervalSince(Fmt.date(call.since))))
        default: return "call ended"
        }
    }

    // MARK: Ringing: decline / accept like iOS

    private var ringingControls: some View {
        VStack(spacing: 26) {
            Button {
                busy = true
                model.answer(speaker: true) { _ in busy = false }
            } label: {
                Label("Answer on Android Speaker", systemImage: "speaker.wave.2.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .glassCapsule(interactive: true)
            }
            .disabled(busy)
            HStack {
                bigButton("Decline", "phone.down.fill", IOSColor.callRed) {
                    busy = true
                    model.endCall { _ in busy = false }
                }
                Spacer()
                bigButton("Accept", "phone.fill", IOSColor.callGreen) {
                    busy = true
                    model.answer(speaker: false) { _ in busy = false }
                }
            }
            .padding(.horizontal, 44)
        }
    }

    // MARK: In call: glass control grid + red end button

    private var activeControls: some View {
        VStack(spacing: 30) {
            GlassGroup {
                HStack(spacing: 26) {
                    control("mute", model.muted ? "mic.slash.fill" : "mic.slash", model.muted) { model.toggleMute() }
                    if model.listening {
                        control("speaker", "speaker.wave.3.fill", model.iphoneSpeaker) { model.toggleIphoneSpeaker() }
                    } else {
                        control("Android speaker", "speaker.wave.3.fill", model.speakerOn) { model.toggleSpeaker() }
                    }
                    if model.canListen {
                        control("listen", model.listening ? "ear.fill" : "ear", model.listening) { model.setListening(!model.listening) }
                    }
                }
            }
            bigButton(nil, "phone.down.fill", IOSColor.callRed) {
                busy = true
                model.endCall { _ in busy = false }
            }
        }
    }

    private func bigButton(_ title: String?, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .glassCircle(tint: color)
            }
            .disabled(busy)
            if let title { Text(title).font(.footnote.weight(.medium)).foregroundStyle(.white) }
        }
    }

    private func control(_ title: String, _ icon: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(on ? Color.black : Color.white)
                    .frame(width: 76, height: 76)
                    .glassCircle(tint: on ? .white : nil)
            }
            Text(title).font(.footnote).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 84)
    }
}

/// Groups glass shapes so they blend like iOS 26 controls (plain container before iOS 26).
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 20) { content }
        } else {
            content
        }
    }
}
