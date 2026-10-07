import Foundation

/// Day keys for spike alerts. Quota periods reset on the provider's clock;
/// "today" for the 15-point alert is a Chicago calendar day, matching Usage Meter.
enum ChicagoDay {
    static let timeZone = TimeZone(identifier: "America/Chicago")!

    static func dateKey(for date: Date) -> String {
        let calendar = makeCalendar()
        let start = calendar.startOfDay(for: date)
        return makeFormatter(format: "yyyy-MM-dd", calendar: calendar).string(from: start)
    }

    static func dayLabel(for dayKey: String) -> String {
        let calendar = makeCalendar()
        let parser = makeFormatter(format: "yyyy-MM-dd", calendar: calendar)
        guard let date = parser.date(from: dayKey) else { return dayKey }
        return makeFormatter(format: "MMM d", calendar: calendar).string(from: date)
    }

    private static func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func makeFormatter(format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
