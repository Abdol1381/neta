import SwiftUI

enum Theme {
    static let accent = Color(red: 0.29, green: 0.36, blue: 1.0)
    static let indigo = accent
    static let good = Color(red: 0.09, green: 0.64, blue: 0.29)
    static let fair = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let poor = Color(red: 0.94, green: 0.27, blue: 0.27)
    static let muted = Color(red: 0.60, green: 0.63, blue: 0.70)
    static let gradient = LinearGradient(colors: [accent, Color(red: 0.42, green: 0.36, blue: 1.0)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let separator = Color(uiColor: .separator).opacity(0.5)

    static func signalColor(_ level: Int, inService: Bool) -> Color {
        guard inService, level > 0 else { return muted }
        switch level {
        case 1: return poor
        case 2: return fair
        default: return good
        }
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }

    /// Phone numbers, codes and keypads read left-to-right even inside the RTL UI.
    func ltr() -> some View { environment(\.layoutDirection, .leftToRight) }
}

/// Small tinted rounded-square icon used in rows.
struct IconBadge: View {
    var systemName: String
    var tint: Color = Theme.accent
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct SectionHeader: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Tag: View {
    var text: String
    var color: Color = Theme.accent

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct SignalBarsView: View {
    var level: Int
    var inService: Bool
    var height: CGFloat = 30
    var barWidth: CGFloat = 7

    var body: some View {
        HStack(alignment: .bottom, spacing: barWidth / 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(inService && i <= level ? Theme.signalColor(level, inService: inService) : Color.gray.opacity(0.22))
                    .frame(width: barWidth, height: height * [0.34, 0.56, 0.78, 1.0][i - 1])
            }
        }
        .frame(height: height, alignment: .bottom)
        .animation(.easeInOut(duration: 0.35), value: level)
        .ltr()
        .accessibilityLabel("آنتن \(level) از ۴")
    }
}

struct Avatar: View {
    var name: String
    var size: CGFloat = 44

    private var initials: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, !first.isNumber, first != "+" else { return "" }
        // One letter reads cleanly for both Persian (joined script) and Latin names.
        return String(first).uppercased()
    }

    private var color: Color {
        let palette: [Color] = [Theme.accent, .indigo, .purple, .orange, .pink, .teal, .green, .blue]
        let h = abs(name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        return palette[h % palette.count]
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.16))
            if initials.isEmpty {
                Image(systemName: "person.fill").foregroundStyle(color).font(.system(size: size * 0.42))
            } else {
                Text(initials).foregroundStyle(color).font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            }
        }
        .frame(width: size, height: size)
    }
}

struct StatusPill: View {
    var conn: ConnState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var color: Color {
        switch conn {
        case .ready: return Theme.good
        case .connecting, .authenticating, .awaitingApproval: return Theme.fair
        default: return Theme.poor
        }
    }

    private var text: String {
        switch conn {
        case .ready: return "متصل"
        case .connecting, .authenticating, .awaitingApproval: return "در حال اتصال…"
        case .idle: return "قطع"
        case .failed: return "در دسترس نیست"
        }
    }
}

struct ToastView: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.horizontal, 24)
    }
}

enum Fmt {
    static let persianCalendar: Calendar = {
        var c = Calendar(identifier: .persian)
        c.locale = Locale(identifier: "fa_IR")
        return c
    }()

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = persianCalendar
        f.locale = Locale(identifier: "fa_IR")
        f.dateFormat = format
        return f
    }

    private static let time = formatter("HH:mm")
    private static let day = formatter("d MMMM")
    private static let full = formatter("d MMMM yyyy")
    private static let weekday = formatter("EEEE")

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    /// Compact: time today, weekday this week, otherwise date.
    static func short(_ ms: Int64) -> String {
        let d = date(ms)
        let cal = persianCalendar
        if cal.isDateInToday(d) { return time.string(from: d) }
        if cal.isDateInYesterday(d) { return "دیروز" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return weekday.string(from: d) }
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) { return day.string(from: d) }
        return full.string(from: d)
    }

    static func clock(_ ms: Int64) -> String { time.string(from: date(ms)) }

    static func dayHeader(_ ms: Int64) -> String {
        let d = date(ms)
        if persianCalendar.isDateInToday(d) { return "امروز" }
        if persianCalendar.isDateInYesterday(d) { return "دیروز" }
        return full.string(from: d)
    }

    static func duration(_ seconds: Int64) -> String {
        let s = Int(max(0, seconds))
        let str = s >= 3600
            ? String(format: "%ld:%02ld:%02ld", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02ld:%02ld", s / 60, s % 60)
        return persianDigits(str)
    }

    static func persianDigits(_ s: String) -> String {
        let map: [Character: Character] = ["0": "۰", "1": "۱", "2": "۲", "3": "۳", "4": "۴", "5": "۵", "6": "۶", "7": "۷", "8": "۸", "9": "۹"]
        return String(s.map { map[$0] ?? $0 })
    }
}
