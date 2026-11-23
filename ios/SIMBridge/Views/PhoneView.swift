import SwiftUI

struct PhoneView: View {
    @EnvironmentObject var model: AppModel
    @State private var segment = TestHooks.phoneSegment

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text("صفحه‌کلید").tag(0)
                    Text("اخیر").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                if segment == 0 { KeypadView() } else { RecentsView() }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("تلفن")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct KeypadView: View {
    @EnvironmentObject var model: AppModel
    @State private var number = ""
    /// Set by a long press so the button tap that follows on finger-up is ignored.
    @State private var suppressTap = false
    @State private var subId: Int?

    private struct Key: Identifiable {
        let digit: String
        let letters: String
        var id: String { digit }
    }

    private let keys: [Key] = [
        Key(digit: "1", letters: ""), Key(digit: "2", letters: "ABC"), Key(digit: "3", letters: "DEF"),
        Key(digit: "4", letters: "GHI"), Key(digit: "5", letters: "JKL"), Key(digit: "6", letters: "MNO"),
        Key(digit: "7", letters: "PQRS"), Key(digit: "8", letters: "TUV"), Key(digit: "9", letters: "WXYZ"),
        Key(digit: "*", letters: ""), Key(digit: "0", letters: "+"), Key(digit: "#", letters: ""),
    ]

    var body: some View {
        GeometryReader { geo in
            // Size keys to the space available so the pad fits from iPhone SE to Pro Max.
            let key = min(78, max(56, (geo.size.height - 250) / 5.2))
            let gap = key * 0.24
            VStack(spacing: gap * 0.8) {
                Spacer(minLength: 4)
                VStack(spacing: 4) {
                    Text(number.isEmpty ? " " : number)
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity)
                        .ltr()
                    Text(model.displayName(for: number) ?? " ")
                        .font(.subheadline).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 24)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(key), spacing: gap * 1.3), count: 3), spacing: gap) {
                    ForEach(keys) { k in
                        Button {
                            if suppressTap { suppressTap = false; return }
                            if number.count < 32 { number.append(k.digit) }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            VStack(spacing: 0) {
                                Text(k.digit).font(.system(size: key * 0.42, weight: .regular, design: .rounded))
                                Text(k.letters).font(.system(size: 9, weight: .semibold)).opacity(0.55).frame(height: 11)
                            }
                            .frame(width: key, height: key)
                            .background(Theme.card, in: Circle())
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            guard k.digit == "0", number.count < 32 else { return }
                            suppressTap = true
                            number.append("+")
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        })
                    }
                }
                .ltr()

                HStack(spacing: gap * 1.3) {
                    Group {
                        if model.sims.count > 1 { SimPicker(subId: $subId) } else { Color.clear }
                    }
                    .frame(width: key, height: key)

                    Button {
                        model.dial(number, subId: subId)
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: key * 0.36))
                            .foregroundStyle(.white)
                            .frame(width: key, height: key)
                            .background(canCall ? Theme.good : Color.gray.opacity(0.35), in: Circle())
                    }
                    .disabled(!canCall)

                    Button {
                        if suppressTap { suppressTap = false; return }
                        if !number.isEmpty { number.removeLast() }
                    } label: {
                        Image(systemName: "delete.left").font(.system(size: 24)).foregroundStyle(.secondary)
                            .frame(width: key, height: key)
                    }
                    .opacity(number.isEmpty ? 0 : 1)
                    .allowsHitTesting(!number.isEmpty)
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                        suppressTap = true
                        number = ""
                    })
                }
                .ltr()

                Text(model.conn.isReady ? " " : "برای تماس، اتصال به گوشی اندروید لازم است")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var canCall: Bool { model.conn.isReady && number.contains(where: { $0.isNumber }) && model.call.isIdle }
}

struct RecentsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.recents.isEmpty {
                EmptyState(icon: "clock", title: "تماسی ثبت نشده", subtitle: "تاریخچه تماس‌های سیم‌کارت اندروید اینجا نمایش داده می‌شود.")
            } else {
                List(model.recents) { c in
                    Button {
                        model.dial(c.number)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(c.type))
                                .foregroundStyle(c.type == "missed" || c.type == "rejected" ? Theme.poor : Theme.indigo)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name.isEmpty ? Phone.ltr(c.title) : c.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(c.type == "missed" ? Theme.poor : .primary)
                                Text(label(c)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Fmt.short(c.date)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(c.number.isEmpty || !model.conn.isReady)
                }
                .listStyle(.plain)
            }
        }
        .refreshable { model.loadRecents() }
        .onAppear { model.loadRecents() }
    }

    private func icon(_ t: String) -> String {
        switch t {
        case "in": return "phone.arrow.down.left"
        case "out": return "phone.arrow.up.right"
        case "missed": return "phone.down"
        case "rejected", "blocked": return "phone.down.circle"
        default: return "phone"
        }
    }

    private func label(_ c: CallLogEntry) -> String {
        let kind: String
        switch c.type {
        case "in": kind = "ورودی"
        case "out": kind = "خروجی"
        case "missed": kind = "از دست رفته"
        case "rejected": kind = "رد شده"
        case "blocked": kind = "مسدود"
        default: kind = "تماس"
        }
        return c.duration > 0 ? "\(kind) · \(Fmt.duration(c.duration))" : kind
    }
}
