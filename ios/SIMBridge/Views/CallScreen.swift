import SwiftUI

struct CallScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var now = Date()
    @State private var busy = false
    @State private var pulse = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var call: CallInfo { model.call }
    private var ringing: Bool { call.state == "ringing" }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.12), Color(red: 0.11, green: 0.13, blue: 0.26)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    Button { model.callScreenMinimized = true } label: {
                        Image(systemName: "chevron.down").font(.title3.weight(.semibold))
                            .padding(12).background(.white.opacity(0.12), in: Circle())
                    }
                    Spacer()
                    if let sim = model.sim(for: call.subId) {
                        HStack(spacing: 6) {
                            SignalBarsView(level: sim.level, inService: sim.inService, height: 14, barWidth: 4)
                            Text(model.sims.count > 1 ? "سیم \(Fmt.persianDigits(String(sim.slot + 1))) · \(sim.title)" : sim.title)
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.white.opacity(0.12), in: Capsule())
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)

                Spacer()

                ZStack {
                    if ringing {
                        Circle()
                            .stroke(.white.opacity(0.18), lineWidth: 2)
                            .frame(width: 110, height: 110)
                            .scaleEffect(pulse ? 1.6 : 1)
                            .opacity(pulse ? 0 : 1)
                            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
                    }
                    Avatar(name: call.name.isEmpty ? call.number : call.name, size: 110)
                        .background(Circle().fill(.white.opacity(0.06)))
                }
                .onAppear { pulse = true }

                VStack(spacing: 6) {
                    Text(call.name.isEmpty ? Phone.ltr(call.number.isEmpty ? "شماره نامشخص" : call.number) : call.name)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                    if !call.name.isEmpty && !call.number.isEmpty {
                        Text(Phone.ltr(call.number)).font(.title3).opacity(0.8)
                    }
                    Text(stateText).font(.headline).opacity(0.85).padding(.top, 4)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)

                Spacer()

                Label(audioHint, systemImage: model.listening ? "ear" : "iphone.radiowaves.left.and.right")
                    .multilineTextAlignment(.center)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.white.opacity(0.1), in: Capsule())

                if ringing { ringingControls } else { activeControls }
            }
            .padding(.bottom, 30)
        }
        .onReceive(timer) { now = $0 }
        .preferredColorScheme(.dark)
    }

    private var audioHint: String {
        if model.listening { return "صدای طرف مقابل روی آیفون · برای صحبت، با گوشی اندروید یا هدست آن صحبت کنید" }
        return "صدای مکالمه روی گوشی اندروید است"
    }

    private var stateText: String {
        switch call.state {
        case "ringing": return "تماس ورودی…"
        case "offhook":
            guard call.since > 0 else { return "در حال تماس" }
            let secs = Int64(now.timeIntervalSince(Fmt.date(call.since)))
            return (call.direction == "out" ? "تماس خروجی · " : "در مکالمه · ") + Fmt.duration(secs)
        default: return "پایان تماس"
        }
    }

    private var ringingControls: some View {
        VStack(spacing: 22) {
            HStack(spacing: 70) {
                roundButton("رد", "phone.down.fill", Theme.poor) {
                    busy = true
                    model.endCall { _ in busy = false }
                }
                roundButton("پاسخ", "phone.fill", Theme.good) {
                    busy = true
                    model.answer(speaker: false) { _ in busy = false }
                }
            }
            Button {
                busy = true
                model.answer(speaker: true) { _ in busy = false }
            } label: {
                Label("پاسخ با بلندگوی اندروید", systemImage: "speaker.wave.2.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.white.opacity(0.15), in: Capsule())
            }
            .disabled(busy)
        }
    }

    private var activeControls: some View {
        VStack(spacing: 26) {
            HStack(spacing: 32) {
                if model.canListen {
                    toggle("شنیدن", model.listening ? "ear.fill" : "ear", model.listening) { model.setListening(!model.listening) }
                }
                if model.listening {
                    toggle("بلندگوی آیفون", model.iphoneSpeaker ? "speaker.wave.3.fill" : "speaker.fill", model.iphoneSpeaker) { model.toggleIphoneSpeaker() }
                } else {
                    toggle("بلندگو", model.speakerOn ? "speaker.wave.3.fill" : "speaker.fill", model.speakerOn) { model.toggleSpeaker() }
                }
                toggle("بی‌صدا", model.muted ? "mic.slash.fill" : "mic.fill", model.muted) { model.toggleMute() }
            }
            roundButton("قطع", "phone.down.fill", Theme.poor) {
                busy = true
                model.endCall { _ in busy = false }
            }
        }
    }

    private func roundButton(_ title: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 78, height: 78)
                    .background(color, in: Circle())
                    .shadow(color: color.opacity(0.5), radius: 12, y: 4)
            }
            .disabled(busy)
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.white)
        }
    }

    private func toggle(_ title: String, _ icon: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(on ? Color.black : Color.white)
                    .frame(width: 66, height: 66)
                    .background(on ? Color.white : Color.white.opacity(0.15), in: Circle())
            }
            Text(title).font(.footnote).foregroundStyle(.white)
        }
    }
}
