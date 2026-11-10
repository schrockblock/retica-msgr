import Foundation

/// One calendar day's run of a chat thread, under its own sticky date header.
public struct MessageDay: Identifiable, Equatable, Sendable {
    /// The start of the day, in the calendar the thread was grouped with.
    public let day: Date
    public let messages: [Message]
    /// The first message's id: unique even if a day's messages are split into two runs.
    public var id: Message.ID { messages[0].id }
}

/// Signal-style dates in a chat thread: a header per day ("Today", "Yesterday", a weekday within the
/// last week, then a date) and a time under each message. A message's `timestamp` is when it was sent
/// (outgoing) or received here (incoming), so the time shown is that.
public enum MessageDays {
    /// Splits a chronological thread into runs of consecutive messages on the same day.
    public static func group(_ messages: [Message], calendar: Calendar) -> [MessageDay] {
        var days: [MessageDay] = []
        var run: [Message] = []
        var runDay: Date?
        for message in messages {
            let day = calendar.startOfDay(for: message.timestamp)
            if let current = runDay, current != day {
                days.append(MessageDay(day: current, messages: run))
                run = []
            }
            runDay = day
            run.append(message)
        }
        if let runDay { days.append(MessageDay(day: runDay, messages: run)) }
        return days
    }

    /// "Today", "Yesterday", a weekday for the five days before that, then "Mon, Nov 2", with the
    /// year added when it is not this year.
    public static func headerText(for day: Date, now: Date, calendar: Calendar = .current,
                                  locale: Locale = .current) -> String {
        let daysAgo = calendar.dateComponents([.day], from: calendar.startOfDay(for: day),
                                              to: calendar.startOfDay(for: now)).day ?? 0
        if daysAgo == 0 { return "Today" }
        if daysAgo == 1 { return "Yesterday" }
        let template: String
        if daysAgo > 1, daysAgo < 7 {
            template = "EEEE"
        } else if calendar.component(.year, from: day) == calendar.component(.year, from: now) {
            template = "EEEMMMd"
        } else {
            template = "EEEMMMdy"
        }
        return formatter(template: template, calendar: calendar, locale: locale).string(from: day)
    }

    /// The short time, in the locale's 12- or 24-hour style.
    public static func timeText(for date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// What VoiceOver reads for the time: "Sent at …" on my messages, "Received at …" on theirs.
    public static func timeAccessibilityLabel(for message: Message, calendar: Calendar = .current,
                                              locale: Locale = .current) -> String {
        let time = timeText(for: message.timestamp, calendar: calendar, locale: locale)
        return (message.isOutgoing ? "Sent at " : "Received at ") + time
    }

    private static func formatter(template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
