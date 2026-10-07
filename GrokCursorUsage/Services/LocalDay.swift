import Foundation

/// Day keys for spike alerts. Quota periods reset on the provider's clock;
/// "today" for the 15-point alert is a calendar day in this Mac's time zone.
enum LocalDay {
    static func dateKey(for date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: date)
        return keyFormatter(calendar: calendar).string(from: start)
    }

    static func dayLabel(for dayKey: String) -> String {
        let calendar = Calendar(identifier: .gregorian)
        guard let date = keyFormatter(calendar: calendar).date(from: dayKey) else { return dayKey }
        let label = DateFormatter()
        label.locale = .current
        label.setLocalizedDateFormatFromTemplate("MMMd")
        return label.string(from: date)
    }

    private static func keyFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
