import Testing
import Foundation
@testable import ReTiCAMsgrCore

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private let us = Locale(identifier: "en_US")

/// 2026-11-09 15:42:00 UTC, a Monday.
private let now = Date(timeIntervalSince1970: 1_794_238_920)

private func at(_ offset: TimeInterval, outgoing: Bool = false) -> Message {
    Message(id: UUID(), peerHex: "aa", isOutgoing: outgoing, body: "hi",
            timestamp: now.addingTimeInterval(offset), status: "delivered", validated: true, messageHash: "")
}

/// Newer ICU puts a narrow no-break space before AM/PM.
private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ")
}

@Test func messageDaysSplitsAtMidnight() {
    let lateYesterday = at(-16 * 3600)           // 2026-11-08 23:42
    let earlyToday = at(-15 * 3600)              // 2026-11-09 00:42
    let later = at(-60)
    let days = MessageDays.group([lateYesterday, earlyToday, later], calendar: utc)
    #expect(days.map(\.messages) == [[lateYesterday], [earlyToday, later]])
    #expect(days.map(\.day) == [utc.startOfDay(for: lateYesterday.timestamp), utc.startOfDay(for: now)])
}

@Test func messageDaysIdIsTheFirstMessageAndEmptyThreadHasNoDays() {
    let first = at(-120)
    let days = MessageDays.group([first, at(-60)], calendar: utc)
    #expect(days.map(\.id) == [first.id])
    #expect(MessageDays.group([], calendar: utc).isEmpty)
}

@Test func messageDayHeaderSaysTodayAndYesterday() {
    #expect(MessageDays.headerText(for: now, now: now, calendar: utc, locale: us) == "Today")
    #expect(MessageDays.headerText(for: now.addingTimeInterval(-86_400), now: now, calendar: utc, locale: us)
            == "Yesterday")
}

@Test func messageDayHeaderNamesTheWeekdayWithinAWeek() {
    // 2026-11-04, a Wednesday, five days back.
    #expect(MessageDays.headerText(for: now.addingTimeInterval(-5 * 86_400), now: now, calendar: utc, locale: us)
            == "Wednesday")
}

@Test func messageDayHeaderShowsTheDateFromAWeekBack() {
    // 2026-11-02, seven days back: a date, no year this year.
    #expect(MessageDays.headerText(for: now.addingTimeInterval(-7 * 86_400), now: now, calendar: utc, locale: us)
            == "Mon, Nov 2")
}

@Test func messageDayHeaderAddsTheYearForAnotherYear() {
    // 2025-11-09.
    #expect(MessageDays.headerText(for: now.addingTimeInterval(-365 * 86_400), now: now, calendar: utc, locale: us)
            == "Sun, Nov 9, 2025")
}

@Test func messageTimeTextIsTheShortTime() {
    #expect(plain(MessageDays.timeText(for: now, calendar: utc, locale: us)) == "3:42 PM")
    #expect(MessageDays.timeText(for: now, calendar: utc, locale: Locale(identifier: "en_GB")) == "15:42")
}

@Test func messageTimeAccessibilitySaysSentOrReceived() {
    #expect(plain(MessageDays.timeAccessibilityLabel(for: at(0, outgoing: true), calendar: utc, locale: us))
            == "Sent at 3:42 PM")
    #expect(plain(MessageDays.timeAccessibilityLabel(for: at(0), calendar: utc, locale: us))
            == "Received at 3:42 PM")
}
