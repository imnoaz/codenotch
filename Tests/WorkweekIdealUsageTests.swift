import XCTest
@testable import Codenotch

final class WorkweekIdealUsageTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // 2027-01-15 00:00:00 UTC, a Friday, at local midnight — chosen so the
    // week's calendar-day chunks line up exactly on real-day boundaries and
    // the linear/weekend math below can be checked by hand. Its week runs
    // Fri -> Fri, touching Fri, Sat, Sun, Mon, Tue, Wed, Thu: Saturday and
    // Sunday are the weekend, the other five are workdays, matching the
    // fixed 5-day/week budget.
    private let resetsAt = Date(timeIntervalSince1970: 1_799_971_200)
    private var cycleStart: Date { resetsAt.addingTimeInterval(-7 * 86_400) }

    private func at(day: Double) -> Date { cycleStart.addingTimeInterval(day * 86_400) }

    private func fraction(_ evalTime: Date) -> Double? {
        WorkweekIdealUsage.idealFraction(resetsAt: resetsAt, evalTime: evalTime, calendar: utcCalendar)
    }

    // MARK: - Linear accumulation on weekdays

    func testWeekdaysAccumulateLinearly() throws {
        // day3 = Monday 00:00, day4 = Tuesday 00:00, day5 = Wednesday 00:00.
        // Monday and Tuesday are both plain weekdays elapsed one at a time,
        // so the ideal fraction climbs by exactly one day's share (10/50)
        // between each point.
        let afterMonday = try XCTUnwrap(fraction(at(day: 4)))
        let afterTuesday = try XCTUnwrap(fraction(at(day: 5)))
        let afterWednesday = try XCTUnwrap(fraction(at(day: 6)))
        XCTAssertEqual(afterMonday, 0.4, accuracy: 1e-9)     // Fri + Mon = 2 workdays
        XCTAssertEqual(afterTuesday, 0.6, accuracy: 1e-9)    // + Tue = 3 workdays
        XCTAssertEqual(afterWednesday, 0.8, accuracy: 1e-9)  // + Wed = 4 workdays
    }

    func testEvalAtCycleStartIsZero() {
        XCTAssertEqual(fraction(cycleStart), 0)
    }

    func testEvalAtResetsAtIsFull() throws {
        let value = try XCTUnwrap(fraction(resetsAt))
        XCTAssertEqual(value, 1, accuracy: 1e-9)
    }

    // MARK: - Weekend stalls the budget

    func testWeekendDoesNotAddBudget() throws {
        // day1 = Saturday 00:00, right after Friday (the week's first
        // workday) finished contributing. day3 = Monday 00:00, right after
        // the whole Sat/Sun weekend has elapsed. No budget should accrue in
        // between.
        let beforeWeekend = try XCTUnwrap(fraction(at(day: 1)))
        let afterWeekend = try XCTUnwrap(fraction(at(day: 3)))
        XCTAssertEqual(beforeWeekend, 0.2, accuracy: 1e-9)
        XCTAssertEqual(afterWeekend, 0.2, accuracy: 1e-9,
                       "no budget hours should accumulate across Saturday and Sunday")
    }

    // MARK: - resetsAt at an arbitrary (non-midnight) time

    func testResetsAtIsNotRequiredToBeMidnight() {
        // A separate, deliberately non-midnight reset (17:59:00 UTC on some
        // Tuesday). cycleStart is exactly resetsAt - 7 days, so it must
        // inherit resetsAt's time-of-day rather than being snapped to
        // midnight.
        let oddResetsAt = Date(timeIntervalSince1970: 1_800_000_000)
        let oddCycleStart = oddResetsAt.addingTimeInterval(-7 * 86_400)
        let components = utcCalendar.dateComponents([.hour, .minute, .second], from: oddCycleStart)
        let resetComponents = utcCalendar.dateComponents([.hour, .minute, .second], from: oddResetsAt)
        XCTAssertEqual(components.hour, resetComponents.hour)
        XCTAssertEqual(components.minute, resetComponents.minute)
        XCTAssertEqual(components.second, resetComponents.second)
        XCTAssertNotEqual(components.hour, 0, "picking a midnight resetsAt would not exercise the offset")

        // And the function still has to accept it without special-casing.
        XCTAssertEqual(WorkweekIdealUsage.idealFraction(resetsAt: oddResetsAt, evalTime: oddCycleStart,
                                                         calendar: utcCalendar), 0)
    }

    // MARK: - DST transitions (Los Angeles)

    private var losAngelesCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    /// Walks the week day by day (via `Calendar.date(byAdding:.day:to:)`, so
    /// DST is respected) and asserts: the week starts at 0, ends at ~1 (a
    /// week containing a transition can be a real hour short or long, which
    /// the ported algorithm's fixed 7*86,400s cycle does not fully absorb —
    /// an acceptable, documented approximation), the fraction never
    /// decreases, it is flat across every calendar day that starts on a
    /// weekend, and it strictly increases across at least one weekday.
    private func assertWellFormedDSTWeek(resetsAt: Date, calendar: Calendar,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        // Calendar-day-based, matching the production fix: the fixed
        // 7*86,400s subtraction the implementation used to use is exactly
        // what issue 1 replaced, because it can disagree with "7 calendar
        // days before resetsAt" by up to an hour across a DST transition
        // (fall-back lengthens the week's real duration past 7*86,400s,
        // spring-forward shortens it). Deriving this helper's own reference
        // `cycleStart` the same way keeps this test checking the algorithm's
        // actual invariants rather than the old, now-incorrect formula.
        let cycleStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: resetsAt),
                                       file: file, line: line)
        XCTAssertEqual(WorkweekIdealUsage.idealFraction(resetsAt: resetsAt, evalTime: cycleStart, calendar: calendar),
                      0, file: file, line: line)
        let atReset = try XCTUnwrap(
            WorkweekIdealUsage.idealFraction(resetsAt: resetsAt, evalTime: resetsAt, calendar: calendar),
            file: file, line: line)
        XCTAssertEqual(atReset, 1, accuracy: 0.02, file: file, line: line)

        var samples: [(value: Double, isWeekend: Bool)] = []
        var cursor = calendar.startOfDay(for: cycleStart)
        for _ in 0...7 {
            let value = try XCTUnwrap(
                WorkweekIdealUsage.idealFraction(resetsAt: resetsAt, evalTime: cursor, calendar: calendar),
                file: file, line: line)
            let weekday = calendar.component(.weekday, from: cursor)
            samples.append((value, weekday == 1 || weekday == 7))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        var sawIncrease = false
        for (before, after) in zip(samples, samples.dropFirst()) {
            XCTAssertLessThanOrEqual(before.value, after.value + 1e-9, "fraction must never decrease",
                                     file: file, line: line)
            if before.isWeekend {
                XCTAssertEqual(before.value, after.value, accuracy: 1e-9,
                               "a weekend day must not add budget", file: file, line: line)
            } else if after.value - before.value > 1e-6 {
                sawIncrease = true
            }
        }
        XCTAssertTrue(sawIncrease, "at least one weekday must add budget", file: file, line: line)
    }

    func testSpringForwardWeekIsWellFormed() throws {
        // 2024-03-10 02:00 America/Los_Angeles is the spring-forward
        // transition (clocks jump to 03:00), which falls inside this week.
        let calendar = losAngelesCalendar
        let laResetsAt = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                        year: 2024, month: 3, day: 15, hour: 12).date!
        try assertWellFormedDSTWeek(resetsAt: laResetsAt, calendar: calendar)
    }

    func testFallBackWeekIsWellFormed() throws {
        // 2024-11-03 02:00 America/Los_Angeles is the fall-back transition
        // (clocks repeat 01:00-02:00), which falls inside this week.
        let calendar = losAngelesCalendar
        let laResetsAt = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                        year: 2024, month: 11, day: 8, hour: 12).date!
        try assertWellFormedDSTWeek(resetsAt: laResetsAt, calendar: calendar)
    }

    // MARK: - endOfToday

    func testEndOfTodayIsNextCalendarDayMidnight() {
        let now = DateComponents(calendar: utcCalendar, timeZone: utcCalendar.timeZone,
                                 year: 2024, month: 6, day: 15, hour: 14, minute: 30).date!
        let expected = DateComponents(calendar: utcCalendar, timeZone: utcCalendar.timeZone,
                                      year: 2024, month: 6, day: 16, hour: 0).date!
        XCTAssertEqual(WorkweekIdealUsage.endOfToday(now: now, calendar: utcCalendar), expected)
    }

    func testEndOfTodayAtMidnightIsTheNextDay() {
        let midnight = DateComponents(calendar: utcCalendar, timeZone: utcCalendar.timeZone,
                                      year: 2024, month: 6, day: 15, hour: 0).date!
        let expected = DateComponents(calendar: utcCalendar, timeZone: utcCalendar.timeZone,
                                      year: 2024, month: 6, day: 16, hour: 0).date!
        XCTAssertEqual(WorkweekIdealUsage.endOfToday(now: midnight, calendar: utcCalendar), expected)
    }

    // MARK: - Condition-based attack cases (A-I from the invariant list)

    // Case A: evalTime one second before cycleStart must clamp to exactly 0,
    // never negative.
    func testEvalTimeOneSecondBeforeCycleStartClampsToZero() {
        let evalTime = cycleStart.addingTimeInterval(-1)
        XCTAssertEqual(fraction(evalTime), 0)
    }

    // Case B: evalTime one hour after resetsAt (clock skew) must clamp to
    // resetsAt's own value, never exceeding 1.
    func testEvalTimeOneHourAfterResetsAtClampsAndNeverExceedsOne() throws {
        let evalTime = resetsAt.addingTimeInterval(3600)
        let value = try XCTUnwrap(fraction(evalTime))
        XCTAssertLessThanOrEqual(value, 1)
        XCTAssertEqual(value, 1, accuracy: 1e-9,
                       "clamping to resetsAt should reproduce the exact at-reset value")
    }

    // Case C: resetsAt pinned to a Saturday midnight so cycleStart is also a
    // Saturday midnight. 24h after cycleStart, only the first (Saturday)
    // chunk has elapsed, and it must contribute 0.
    func testFirstWeekendChunkAfterSaturdayAlignedResetContributesZero() throws {
        let saturdayResetsAt = DateComponents(calendar: utcCalendar, timeZone: utcCalendar.timeZone,
                                              year: 2024, month: 6, day: 15, hour: 0).date!
        XCTAssertEqual(utcCalendar.component(.weekday, from: saturdayResetsAt), 7,
                       "sanity: 2024-06-15 must be a Saturday for this case to exercise a weekend-first chunk")
        let saturdayCycleStart = saturdayResetsAt.addingTimeInterval(-7 * 86_400)
        let evalTime = saturdayCycleStart.addingTimeInterval(86_400)
        let value = try XCTUnwrap(WorkweekIdealUsage.idealFraction(
            resetsAt: saturdayResetsAt, evalTime: evalTime, calendar: utcCalendar))
        XCTAssertEqual(value, 0, "the first 24h chunk (a Saturday) must not add any budget")
    }

    // Cases D & E: DST-shortened/lengthened calendar days that start on a
    // weekend must still contribute 0, regardless of their real duration.
    //
    // Note: the attack-case list describes the spring-forward day
    // (2024-03-10) as landing on a "Saturday", but US DST always starts at
    // 2am on a Sunday, so 2024-03-10 is in fact a Sunday (weekday 1), not a
    // Saturday. That is corrected here; the underlying invariant under test
    // (a weekend-starting DST chunk contributes 0) is unaffected, since
    // Sunday is weekend too.
    func testDSTSpringForwardWeekendDayContributesZeroDespiteBeingOnly23Hours() throws {
        let calendar = losAngelesCalendar
        let dayStart = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                      year: 2024, month: 3, day: 10).date!
        XCTAssertEqual(calendar.component(.weekday, from: dayStart), 1,
                       "sanity: 2024-03-10 is actually a Sunday, not a Saturday as the case description assumed")
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        XCTAssertEqual(dayEnd.timeIntervalSince(dayStart), 23 * 3600, accuracy: 1,
                       "sanity: spring-forward day must be exactly 23 real hours")

        let resetsAt = dayEnd
        let before = try XCTUnwrap(WorkweekIdealUsage.idealFraction(
            resetsAt: resetsAt, evalTime: dayStart, calendar: calendar))
        let after = try XCTUnwrap(WorkweekIdealUsage.idealFraction(
            resetsAt: resetsAt, evalTime: dayEnd, calendar: calendar))
        XCTAssertEqual(before, after, accuracy: 1e-9,
                       "the 23h Sunday chunk must add 0 budget despite its non-24h real duration")
    }

    func testDSTFallBackWeekendDayContributesZeroDespiteBeingFull25Hours() throws {
        let calendar = losAngelesCalendar
        let dayStart = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                      year: 2024, month: 11, day: 3).date!
        XCTAssertEqual(calendar.component(.weekday, from: dayStart), 1,
                       "sanity: 2024-11-03 must be a Sunday for this case")
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        XCTAssertEqual(dayEnd.timeIntervalSince(dayStart), 25 * 3600, accuracy: 1,
                       "sanity: fall-back day must be exactly 25 real hours")

        let resetsAt = dayEnd
        let before = try XCTUnwrap(WorkweekIdealUsage.idealFraction(
            resetsAt: resetsAt, evalTime: dayStart, calendar: calendar))
        let after = try XCTUnwrap(WorkweekIdealUsage.idealFraction(
            resetsAt: resetsAt, evalTime: dayEnd, calendar: calendar))
        XCTAssertEqual(before, after, accuracy: 1e-9,
                       "the 25h Sunday chunk must add 0 budget despite its non-24h real duration")
    }

    // Case F: whatever time of day resetsAt falls at, the 7 calendar days
    // starting at cycleStart's own calendar day must contain exactly 5
    // weekdays and 2 weekend days. This mirrors the exact day-walking
    // primitives the implementation uses (calendar.startOfDay +
    // date(byAdding: .day)), without depending on its internal loop.
    private func weekendDayCount(cycleStart: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: cycleStart)
        var count = 0
        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            let weekday = calendar.component(.weekday, from: day)
            if weekday == 1 || weekday == 7 { count += 1 }
        }
        return count
    }

    func testWeekComposition_TuesdayEveningReset_HasFiveWeekdaysAndTwoWeekendDays() {
        let resetsAt = DateComponents(calendar: utcCalendar, timeZone: utcCalendar.timeZone,
                                      year: 2024, month: 6, day: 4, hour: 17, minute: 59).date!
        XCTAssertEqual(utcCalendar.component(.weekday, from: resetsAt), 3, "sanity: must be a Tuesday")
        let cycleStart = resetsAt.addingTimeInterval(-7 * 86_400)
        XCTAssertEqual(weekendDayCount(cycleStart: cycleStart, calendar: utcCalendar), 2)
    }

    func testWeekComposition_FridayMorningReset_HasFiveWeekdaysAndTwoWeekendDays() {
        let resetsAt = DateComponents(calendar: utcCalendar, timeZone: utcCalendar.timeZone,
                                      year: 2024, month: 6, day: 7, hour: 9).date!
        XCTAssertEqual(utcCalendar.component(.weekday, from: resetsAt), 6, "sanity: must be a Friday")
        let cycleStart = resetsAt.addingTimeInterval(-7 * 86_400)
        XCTAssertEqual(weekendDayCount(cycleStart: cycleStart, calendar: utcCalendar), 2)
    }

    func testWeekComposition_SundayEarlyMorningReset_HasFiveWeekdaysAndTwoWeekendDays() {
        let resetsAt = DateComponents(calendar: utcCalendar, timeZone: utcCalendar.timeZone,
                                      year: 2024, month: 6, day: 9, hour: 0, minute: 1).date!
        XCTAssertEqual(utcCalendar.component(.weekday, from: resetsAt), 1, "sanity: must be a Sunday")
        let cycleStart = resetsAt.addingTimeInterval(-7 * 86_400)
        XCTAssertEqual(weekendDayCount(cycleStart: cycleStart, calendar: utcCalendar), 2)
    }

    // Case G: idealFraction(now) must never exceed idealFraction(endOfToday(now)).
    func testMonotonic_WeekdayNoonNeverExceedsEndOfTodayValue() throws {
        let wednesdayNoon = at(day: 5).addingTimeInterval(12 * 3600)
        let endOfToday = WorkweekIdealUsage.endOfToday(now: wednesdayNoon, calendar: utcCalendar)
        let before = try XCTUnwrap(fraction(wednesdayNoon))
        let after = try XCTUnwrap(fraction(endOfToday))
        XCTAssertLessThanOrEqual(before, after + 1e-9)
    }

    func testMonotonic_WeekendNoonNeverExceedsEndOfTodayValue() throws {
        // Saturday noon: both the current instant and the following midnight
        // (Sunday 00:00) fall inside the zero-contribution weekend, so the
        // two values may be equal, but "<=" must still hold.
        let saturdayNoon = at(day: 1).addingTimeInterval(12 * 3600)
        let endOfToday = WorkweekIdealUsage.endOfToday(now: saturdayNoon, calendar: utcCalendar)
        let before = try XCTUnwrap(fraction(saturdayNoon))
        let after = try XCTUnwrap(fraction(endOfToday))
        XCTAssertLessThanOrEqual(before, after + 1e-9)
        XCTAssertEqual(before, after, accuracy: 1e-9,
                       "Saturday does not accrue budget, so noon and the following midnight should match")
    }

    // 追加: invariant 4 also quantifies over "the last day of the week",
    // which case G's two examples (a mid-week weekday and a weekend day)
    // do not exercise on their own.
    func testMonotonic_LastWeekdayNoonNeverExceedsResetEndOfTodayValue() throws {
        let thursdayNoon = at(day: 6).addingTimeInterval(12 * 3600)
        let endOfToday = WorkweekIdealUsage.endOfToday(now: thursdayNoon, calendar: utcCalendar)
        XCTAssertEqual(endOfToday, resetsAt, "sanity: Thursday's end-of-day must land exactly on the Friday reset")
        let before = try XCTUnwrap(fraction(thursdayNoon))
        let after = try XCTUnwrap(fraction(endOfToday))
        XCTAssertLessThanOrEqual(before, after + 1e-9)
    }

    // Case H: exact boundary value at evalTime == resetsAt.
    // The non-DST part is already covered by testEvalAtResetsAtIsFull above;
    // this adds the DST-week counterpart with its documented tolerance.
    func testEvalAtResetsAtIsApproximatelyOneAcrossDSTWeeks() throws {
        let calendar = losAngelesCalendar
        let springResetsAt = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                            year: 2024, month: 3, day: 15, hour: 12).date!
        let fallResetsAt = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                          year: 2024, month: 11, day: 8, hour: 12).date!
        for (resetsAt, label) in [(springResetsAt, "spring-forward week"), (fallResetsAt, "fall-back week")] {
            let value = try XCTUnwrap(WorkweekIdealUsage.idealFraction(
                resetsAt: resetsAt, evalTime: resetsAt, calendar: calendar))
            XCTAssertEqual(value, 1, accuracy: 0.02, "\(label): DST week may be off from 1.0 by a small, documented amount")
        }
    }

    // Case I: endOfToday must always land on the *next* calendar day's
    // midnight, even when `now` already is a midnight (no same-instant bug).
    // Already fully exercised by testEndOfTodayIsNextCalendarDayMidnight
    // (mid-day `now`) and testEndOfTodayAtMidnightIsTheNextDay (exact-midnight
    // `now`) above; this adds the exact dates named in the case list as a
    // direct, explicit check.
    func testEndOfToday_MidDayAndExactMidnight_BothReturnNextCalendarDayMidnight() {
        let midDay = DateComponents(calendar: utcCalendar, timeZone: utcCalendar.timeZone,
                                    year: 2024, month: 6, day: 5, hour: 12).date!
        let exactMidnight = DateComponents(calendar: utcCalendar, timeZone: utcCalendar.timeZone,
                                           year: 2024, month: 6, day: 5, hour: 0).date!
        let expected = DateComponents(calendar: utcCalendar, timeZone: utcCalendar.timeZone,
                                      year: 2024, month: 6, day: 6, hour: 0).date!
        XCTAssertEqual(WorkweekIdealUsage.endOfToday(now: midDay, calendar: utcCalendar), expected)
        XCTAssertEqual(WorkweekIdealUsage.endOfToday(now: exactMidnight, calendar: utcCalendar), expected,
                       "midnight `now` must not be treated as already being its own end-of-day")
        XCTAssertNotEqual(WorkweekIdealUsage.endOfToday(now: exactMidnight, calendar: utcCalendar), exactMidnight)
    }

    // MARK: - Regression: DST week must still contain exactly 2 weekend days
    // (constructed counterexample: America/Los_Angeles, resetsAt = 2024-03-11
    // 00:30 PDT. A fixed-604,800-second cycleStart lands an hour earlier than
    // the calendar day exactly 7 days before resetsAt, because the week
    // contains the 2024-03-10 spring-forward transition (a 23h day). That
    // extra hour used to spill the walk into an additional partial-day chunk
    // classified as weekend, making 3 weekend chunks instead of 2. cycleStart
    // must be computed in calendar days (`Calendar.date(byAdding: .day,
    // value: -7, to:)`), not fixed seconds, so it always lines up with the
    // day-by-day chunk walk below.
    func testDSTWeekAlwaysHasExactlyTwoWeekendChunks() throws {
        let calendar = losAngelesCalendar
        let resetsAt = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                      year: 2024, month: 3, day: 11, hour: 0, minute: 30).date!
        // Sanity: this reset time is mid-week (a Monday), and the fixed
        // 604,800s subtraction really does land on a different local
        // calendar day than the calendar-day-based cycleStart would.
        let fixedSecondsCycleStart = resetsAt.addingTimeInterval(-7 * 86_400)
        let calendarDayCycleStart = try XCTUnwrap(
            calendar.date(byAdding: .day, value: -7, to: resetsAt))
        XCTAssertNotEqual(fixedSecondsCycleStart, calendarDayCycleStart,
                          "sanity: the DST week must make the two cycleStart computations disagree")

        // Walk the 7 calendar days from cycleStart and count how many chunks
        // the implementation's own day-boundary primitives classify as
        // weekend (Sunday=1, Saturday=7). This must always be exactly 2,
        // matching the fixed 5-weekday/2-weekend-day budget.
        var weekendChunks = 0
        var cursor = calendar.startOfDay(for: calendarDayCycleStart)
        for _ in 0..<7 {
            let weekday = calendar.component(.weekday, from: cursor)
            if weekday == 1 || weekday == 7 { weekendChunks += 1 }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        XCTAssertEqual(weekendChunks, 2,
                       "a DST week must still contain exactly 2 weekend chunks, never 3")

        // And the fraction itself must reach ~1 at resetsAt (allowing the
        // same small DST-week tolerance used elsewhere in this file), not
        // overshoot past 1 from an extra spurious weekend-classified chunk.
        let value = try XCTUnwrap(WorkweekIdealUsage.idealFraction(
            resetsAt: resetsAt, evalTime: resetsAt, calendar: calendar))
        XCTAssertEqual(value, 1, accuracy: 0.02)
    }

    // MARK: - isEligible (issue 2 / issue 5 direct coverage)

    private func window(id: String, resetsAt: Date? = Date(), usedFraction: Double? = 0.5) -> LimitWindow {
        LimitWindow(id: id, label: id, usedFraction: usedFraction, resetsAt: resetsAt)
    }

    func testIsEligible_ClaudeWeeklyWindowWithResetAndUsage_IsEligible() {
        XCTAssertTrue(WorkweekIdealUsage.isEligible(window(id: "weekly_all"), providerID: "claude"))
    }

    func testIsEligible_ClaudeProfileWeeklyWindow_IsEligible() {
        // A named Claude profile (e.g. "claude-work") is still Claude.
        XCTAssertTrue(WorkweekIdealUsage.isEligible(window(id: "weekly_opus"), providerID: "claude-work"))
    }

    func testIsEligible_NonWeeklyPrefix_IsNotEligible() {
        XCTAssertFalse(WorkweekIdealUsage.isEligible(window(id: "session"), providerID: "claude"))
    }

    func testIsEligible_NilResetsAt_IsNotEligible() {
        XCTAssertFalse(WorkweekIdealUsage.isEligible(window(id: "weekly_all", resetsAt: nil), providerID: "claude"))
    }

    func testIsEligible_NonClaudeProvider_IsNotEligible() {
        // A hypothetical non-Claude provider using a "weekly_" id must not be
        // eligible: only Claude gets the workweek reference bars.
        XCTAssertFalse(WorkweekIdealUsage.isEligible(window(id: "weekly_trial"), providerID: "openai"))
    }

    func testIsEligible_ClaudeLikePrefixButNotClaude_IsNotEligible() {
        // "claudeish" is not "claude" and not "claude-<slug>" — must not be
        // mistaken for a Claude profile via a naive prefix check.
        XCTAssertFalse(WorkweekIdealUsage.isEligible(window(id: "weekly_all"), providerID: "claudeish"))
    }

    func testIsEligible_NilUsedFraction_IsNotEligible() {
        // Issue 5: the workweek bars sit under the existing usage bar, so
        // they must not appear (or reserve height) when that bar itself
        // isn't drawn.
        XCTAssertFalse(WorkweekIdealUsage.isEligible(window(id: "weekly_all", usedFraction: nil), providerID: "claude"))
    }
}
