import Foundation

/// How much of Claude's weekly allowance you would have burned by now if you
/// worked it like a job: 10 hours a day, Monday through Friday, nothing on
/// the weekend. Ported from the claude-period Chrome extension's
/// `calculateElapsedBudgetHours` / `calculateIdealUsage`, so the notch's
/// tooltip and the extension's usage page tell the same story about "how much
/// AI is it okay to have used today".
///
/// Unrelated to `DailyPace`: that feature turns the weekly window into its
/// own ring under a six-day-a-week assumption. This one draws a pair of thin
/// reference bars *under* the existing weekly bar, comparing what was
/// actually used against a five-day, 10-hour workweek. Neither reads from nor
/// writes to the other.
enum WorkweekIdealUsage {
    /// Fixed by spec, not user-configurable: a workweek is 5 days of 10 hours.
    static let hoursPerDay: Double = 10
    static let daysPerWeek: Double = 5
    static let totalBudgetHours: Double = hoursPerDay * daysPerWeek
    static let cycleLength: TimeInterval = 7 * 86_400

    /// Calendar used to find local day boundaries and weekdays. Gregorian +
    /// the device's own time zone, matching the convention already used by
    /// `DeepSeekPricing` (UTC variant) and `GeminiTokenUsage` (local variant).
    static var defaultCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// The share of a 50-hour (10h/day * 5 days) weekly budget that should
    /// have been spent by `evalTime`, given the window resets at `resetsAt`.
    ///
    /// The week is always the 7 days ending at `resetsAt` — the same fixed
    /// cycle the provider bills against, regardless of when the account first
    /// started using Claude. `evalTime` is clamped into `[cycleStart,
    /// resetsAt]` first, so a small clock disagreement between the provider
    /// and this device never produces a negative or over-100% figure.
    ///
    /// Days are walked one calendar day at a time via `Calendar.date(byAdding
    /// :.day, value: 1, to:)` rather than by adding a fixed 86,400 seconds, so
    /// a DST transition inside the week does not shift which local calendar
    /// day — and therefore which weekday — a chunk belongs to. A chunk that
    /// is short (23h, spring-forward) or long (25h, fall-back) because of that
    /// transition is still credited proportionally
    /// (`hoursInChunk / 24 * hoursPerDay`), uncapped, exactly as the ported
    /// JavaScript does.
    static func idealFraction(resetsAt: Date, evalTime: Date,
                              calendar: Calendar = defaultCalendar) -> Double? {
        // Walked in calendar days, not fixed seconds, so this matches the
        // day-by-day chunk boundaries below exactly even across a DST
        // transition inside the week (see the DST test cases in
        // WorkweekIdealUsageTests). Falls back to the fixed-seconds
        // computation only if the calendar can't produce the date at all.
        let cycleStart = calendar.date(byAdding: .day, value: -7, to: resetsAt)
            ?? resetsAt.addingTimeInterval(-cycleLength)
        let clampedEval = min(max(evalTime, cycleStart), resetsAt)

        var elapsedBudgetHours = 0.0
        var cursor = cycleStart
        while cursor < clampedEval {
            let dayStart = calendar.startOfDay(for: cursor)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let segmentEnd = min(dayEnd, clampedEval)
            let hoursInSegment = segmentEnd.timeIntervalSince(cursor) / 3600

            let weekday = calendar.component(.weekday, from: dayStart)
            let isWeekend = weekday == 1 || weekday == 7  // Sunday, Saturday
            if !isWeekend {
                elapsedBudgetHours += (hoursInSegment / 24) * hoursPerDay
            }
            cursor = dayEnd
        }
        return min(1, max(0, elapsedBudgetHours / totalBudgetHours))
    }

    /// Local midnight at the start of the calendar day *after* `now` — the
    /// moment through which "what's okay to have used today" is measured.
    static func endOfToday(now: Date, calendar: Calendar = defaultCalendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
    }

    /// Only Claude's `weekly_*` windows (`weekly_all`, `weekly_opus`, the
    /// per-model ones, …) get the workweek reference bars, and only when a
    /// reset date exists to anchor the week to, and only when the existing
    /// usage bar itself is drawn (`usedFraction != nil`) — the workweek bars
    /// are meant to sit *under* that bar, never stand alone. The single
    /// source of truth for this test, so the bar's own draw condition
    /// (`LimitWindowRow`) and every `cardHeight` caller's reserved-row count
    /// can never drift apart.
    static func isEligible(_ window: LimitWindow, providerID: String) -> Bool {
        ClaudeProfile.isClaude(providerID: providerID)
            && window.id.hasPrefix("weekly_")
            && window.resetsAt != nil
            && window.usedFraction != nil
    }
}
