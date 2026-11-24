import SwiftUI

/// In-app call screen laid out like the iPhone's own (iOS 26): status above the name, a 3 × 2 grid of
/// glass buttons with the red End button in the middle, and Remind Me / Message above Decline / Accept
/// while ringing. Call audio is automatic — there is nothing to switch on.
struct CallScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var now = Date()
    @State private var busy = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var call: CallInfo { model.call }
    private var ringing: Bool { call.state == "ringing" }
    private var title: String {
        call.name.isEmpty ? (call.number.isEmpty ? "Unknown" : Phone.ltr(call.number)) : call.name
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
                    .accessibilityLabel("Back to App")
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, 8)

                // Status line above a large name, as in iOS 17 and later.
                VStack(spacing: 4) {
                    Text(statusLine)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(title)
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                    if !call.name.isEmpty && !call.number.isEmpty {
                        Text(Phone.ltr(call.number)).font(.subheadline).foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)

                Spacer()

                if ringing { ringingControls } else { activeControls }
            }
            .padding(.bottom, 40)
        }
        .onReceive(timer) { now = $0 }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: call.state)
    }

    /// Dark gradient with a blurred monogram glow (contact-poster feel).
    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.18), Color(red: 0.03, green: 0.03, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            Avatar(name: call.name.isEmpty ? call.number : call.name, size: 420)
                .blur(radius: 90)
                .opacity(0.4)
                .offset(y: -160)
        }
        .ignoresSafeArea()
    }

    private var simLabel: String? {
        guard let sim = model.sim(for: call.subId) else { return nil }
        return model.sims.count > 1 ? "SIM \(sim.slot + 1) · \(sim.title)" : sim.title
    }

    private var statusLine: String {
        if !model.conn.isReady { return "reconnecting…" }
        switch call.state {
        case "ringing": return simLabel.map { "\($0) · mobile" } ?? "mobile"
        case "offhook":
            guard call.since > 0 else { return call.direction == "out" ? "calling…" : "connecting…" }
            return Fmt.duration(Int64(max(0, now.timeIntervalSince(Fmt.date(call.since)))))
        default: return "Call Ended"
        }
    }

    // MARK: Ringing

    private var ringingControls: some View {
        VStack(spacing: 34) {
            HStack {
                smallAction("Remind Me", "alarm.fill") {
                    busy = true
                    model.remindMe(call)
                    model.endCall { _ in busy = false }
                }
                Spacer()
                smallAction("Message", "message.fill") {
                    busy = true
                    model.declineWithMessage(call)
                    busy = false
                }
            }
            HStack {
                circle("Decline", "phone.down.fill", tint: IOSColor.callRed) {
                    busy = true
                    model.endCall { _ in busy = false }
                }
                Spacer()
                circle("Accept", "phone.fill", tint: IOSColor.callGreen) {
                    busy = true
                    model.answer(speaker: false) { _ in busy = false }
                }
            }
        }
        .padding(.horizontal, 44)
        .disabled(busy)
    }

    private func smallAction(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22))
                Text(title).font(.footnote.weight(.medium))
            }
            .foregroundStyle(.white)
            .frame(width: 92)
        }
    }

    // MARK: In call: 3 × 2 grid

    private var speakerOn: Bool { model.listening ? model.iphoneSpeaker : model.speakerOn }

    private var activeControls: some View {
        GlassGroup {
            VStack(spacing: 22) {
                HStack(spacing: 0) {
                    circle("Speaker", speakerOn ? "speaker.wave.3.fill" : "speaker.wave.2.fill", on: speakerOn) {
                        if model.listening { model.toggleIphoneSpeaker() } else { model.toggleSpeaker() }
                    }
                    Spacer()
                    circle("FaceTime", "video.fill", enabled: false) {}
                    Spacer()
                    circle("Mute", model.muted ? "mic.slash.fill" : "mic.slash", on: model.muted) { model.toggleMute() }
                }
                HStack(spacing: 0) {
                    moreMenu
                    Spacer()
                    circle("End", "phone.down.fill", tint: IOSColor.callRed) {
                        busy = true
                        model.endCall { _ in busy = false }
                    }
                    .disabled(busy)
                    Spacer()
                    circle("Keypad", "circle.grid.3x3.fill", enabled: false) {}
                }
            }
            .padding(.horizontal, 36)
        }
    }

    /// "More": the Android phone's own loudspeaker (when the call audio plays on the Android phone).
    private var moreMenu: some View {
        VStack(spacing: 8) {
            Menu {
                Button {
                    model.toggleSpeaker()
                } label: {
                    Label(model.speakerOn ? "Turn Off Android Speaker" : "Android Speaker", systemImage: "speaker.wave.3")
                }
                Button {
                    model.callScreenMinimized = true
                } label: {
                    Label("Back to App", systemImage: "square.grid.2x2")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 78, height: 78)
                    .glassCircle()
            }
            Text("More").font(.footnote).foregroundStyle(.white).lineLimit(1)
        }
        .frame(width: 86)
    }

    /// Round glass button with its label underneath. `on` fills it white like iOS's selected state.
    private func circle(_ title: String, _ icon: String, on: Bool = false, tint: Color? = nil, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: tint == nil ? 26 : 30, weight: tint == nil ? .medium : .semibold))
                    .foregroundStyle(on ? Color.black : Color.white)
                    .frame(width: 78, height: 78)
                    .glassCircle(tint: on ? .white : tint)
            }
            .disabled(!enabled)
            Text(title).font(.footnote).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 86)
        .opacity(enabled ? 1 : 0.35)
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
