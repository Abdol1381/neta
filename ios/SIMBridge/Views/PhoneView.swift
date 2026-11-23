import SwiftUI

struct PhoneView: View {
    @EnvironmentObject var model: AppModel
    @State private var segment = 0

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
        VStack(spacing: 14) {
            Spacer(minLength: 8)
            VStack(spacing: 4) {
                Text(number.isEmpty ? " " : number)
                    .font(.system(size: 36, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)
                    .ltr()
                Text(model.displayName(for: number) ?? " ")
                    .font(.subheadline).foregroundStyle(Theme.indigo)
            }
            .padding(.horizontal, 24)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 22), count: 3), spacing: 16) {
                ForEach(keys) { k in
                    Button {
                        if number.count < 32 { number.append(k.digit) }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        VStack(spacing: 0) {
                            Text(k.digit).font(.system(size: 34, weight: .regular, design: .rounded))
                            Text(k.letters).font(.system(size: 10, weight: .semibold)).opacity(0.6).frame(height: 12)
                        }
                        .frame(width: 80, height: 80)
                        .background(Theme.card, in: Circle())
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                        if k.digit == "0" { number = String(number.dropLast()) + "+" }
                    })
                }
            }
            .ltr()

            HStack(spacing: 36) {
                Group {
                    if model.sims.count > 1 { SimPicker(subId: $subId) } else { Color.clear }
                }
                .frame(width: 64, height: 64)

                Button {
                    model.dial(number, subId: subId)
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                        .frame(width: 80, height: 80)
                        .background(canCall ? Theme.good : Color.gray.opacity(0.4), in: Circle())
                }
                .disabled(!canCall)

                Button {
                    if !number.isEmpty { number.removeLast() }
                } label: {
                    Image(systemName: "delete.left.fill").font(.system(size: 26)).foregroundStyle(.secondary)
                        .frame(width: 64, height: 64)
                }
                .opacity(number.isEmpty ? 0 : 1)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in number = "" })
            }
            .ltr()

            if !model.conn.isReady {
                Text("برای تماس، اتصال به گوشی اندروید لازم است").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
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
