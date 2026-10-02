import XCTest
import Combine
@testable import Codenotch

/// A reload whose inputs are those of the last computation must not read the
/// database again, and must not republish what the card already shows.
@MainActor
final class CostModelReloadTests: XCTestCase {
    private var base: URL!
    private var store: CostStore!
    private var savedRange: Any?
    private var price = CostModelReloadTests.pricer(output: 25)
    private var account: CostAccount!

    private static func pricer(output: Double) -> Pricer {
        Pricer(prices: [ModelPrice(model: "claude-x", input: 5, output: output, cacheRead: 0.5, cacheWrite: 6.25)], rate: 1)
    }

    override func setUp() async throws {
        savedRange = UserDefaults.standard.object(forKey: "costRange")
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostModelReloadTests-\(UUID().uuidString)", isDirectory: true)
        store = try XCTUnwrap(CostStore(url: base.appendingPathComponent("db.sqlite")))
        account = CostAccount(id: "reload-test", provider: "claude", name: "Test",
                              configDirectory: URL(fileURLWithPath: "/nonexistent"), billing: .api)
    }

    override func tearDown() async throws {
        if let savedRange { UserDefaults.standard.set(savedRange, forKey: "costRange") }
        else { UserDefaults.standard.removeObject(forKey: "costRange") }
        store = nil
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Fixtures

    private func makeModel(_ range: CostRange) async -> CostModel {
        let m = CostModel(account: account, store: store, pricer: { [unowned self] in self.price })
        m.range = range
        await settle(m)
        return m
    }

    /// Reloads are serialized, so awaiting a new one waits for every earlier one.
    private func settle(_ m: CostModel) async {
        await m.reload()?.value
    }

    private var key = 0
    private func commit(_ project: String, output: Int = 1_000, agoSeconds: Int = 5) {
        key += 1
        let e = UsageEvent(ts: Int(Date().timeIntervalSince1970) - agoSeconds, sessionId: "s-\(project)",
                           dedupeKey: "r:\(key)", project: project, cwd: project, branch: nil, model: "claude-x",
                           input: 100, output: output, cacheRead: 0, cacheWrite: 0, ccVersion: nil)
        XCTAssertTrue(store.commit(events: [e], path: "/f/\(key)", inode: key, size: 1, offset: 1, mtime: 0))
    }

    // MARK: (1) unchanged inputs

    func testUnchangedInputsDoNotRecompute() async {
        commit("/p/a")
        let m = await makeModel(.today)
        let after = m.recomputations
        XCTAssertGreaterThanOrEqual(after.rows, 1)
        XCTAssertGreaterThanOrEqual(after.usage, 1)
        XCTAssertEqual(m.state, .ready)

        await settle(m)
        await settle(m)
        XCTAssertEqual(m.recomputations, after)
    }

    // MARK: (2) a committed turn

    func testACommittedTurnRecomputesRowsAndUsage() async {
        commit("/p/a")
        let m = await makeModel(.today)
        let before = m.recomputations
        let lifetime = m.tokenUsage?.summary?.lifetimeTokens

        commit("/p/b")
        await settle(m)
        XCTAssertEqual(m.recomputations, .init(rows: before.rows + 1, usage: before.usage + 1))
        XCTAssertEqual(Set(m.rows.map(\.project)), ["/p/a", "/p/b"])
        XCTAssertEqual(m.tokenUsage?.summary?.lifetimeTokens, (lifetime ?? 0) + 1_100)
    }

    func testACursorOnlyCommitDoesNotRecompute() async {
        commit("/p/a")
        let m = await makeModel(.today)
        let writes = store.writes()
        let before = m.recomputations

        XCTAssertTrue(store.commit(events: [], path: "/f/cursor-only", inode: 999, size: 10, offset: 10, mtime: 0))
        XCTAssertEqual(store.writes(), writes)
        await settle(m)
        XCTAssertEqual(m.recomputations, before)
    }

    // MARK: (3) other inputs

    func testRangePriceQuotaAndSamplesRecomputeRowsOnly() async {
        commit("/p/a")
        let m = await makeModel(.today)
        var expected = m.recomputations

        m.range = .month
        await settle(m)
        expected.rows += 1
        XCTAssertEqual(m.recomputations, expected, "range")

        let cheap = m.rows.first?.cost
        price = Self.pricer(output: 50)
        await settle(m)
        expected.rows += 1
        XCTAssertEqual(m.recomputations, expected, "price")
        XCTAssertNotEqual(m.rows.first?.cost, cheap)

        // A login with no rolling windows stops being quota-backed.
        m.observe([ProviderSnapshot(id: account.id, displayName: "T", glyph: .third, fidelity: .official,
                                    status: .ok, windows: [], headlineID: "w")])
        XCTAssertFalse(m.quotaBacked)
        await settle(m)
        expected.rows += 1
        XCTAssertEqual(m.recomputations, expected, "quotaBacked")

        // A limit reading changes what the window views read, not the turns.
        store.recordSample(window: .weekly, pct: 10)
        await settle(m)
        expected.rows += 1
        XCTAssertEqual(m.recomputations, expected, "sample")
    }

    /// Two windows whose periods began at the same second read the same
    /// interval but different limits: the range itself is an input.
    func testSwitchingWindowsOverTheSameIntervalRecomputes() async {
        let periodStart = Date().addingTimeInterval(-60)
        commit("/p/a")
        store.recordSample(window: .session, pct: 5,
                           resetsAt: periodStart.addingTimeInterval(CostWindow.session.duration))
        store.recordSample(window: .weekly, pct: 10,
                           resetsAt: periodStart.addingTimeInterval(CostWindow.weekly.duration))
        let m = await makeModel(.session)
        XCTAssertEqual(m.rows.map(\.pct), [5])

        m.range = .weekly
        await settle(m)
        XCTAssertEqual(m.rows.map(\.pct), [10])
    }

    // MARK: (3b) time and allowance inputs

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private static func local(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func makeModel(_ range: CostRange, clock: Clock, account: CostAccount? = nil) async -> CostModel {
        let m = CostModel(account: account ?? self.account, store: store,
                          pricer: { [unowned self] in self.price }, clock: { clock.now })
        m.range = range
        await settle(m)
        return m
    }

    /// "Today" starts at midnight: the next day reads a new interval with the
    /// same turns, inside the same month.
    func testANewDayRecomputesTheDayRange() async {
        commit("/p/a")
        let clock = Clock(Self.local(3, 15))
        let m = await makeModel(.today, clock: clock)
        var expected = m.recomputations

        clock.now = Self.local(3, 15, 18)
        await settle(m)
        XCTAssertEqual(m.recomputations, expected, "same day, same interval")

        clock.now = Self.local(3, 16)
        await settle(m)
        expected.rows += 1
        expected.usage += 1
        XCTAssertEqual(m.recomputations, expected, "from")
    }

    /// All time starts at 0 whatever the clock says; only the month the
    /// subscription share is spread over moves.
    func testANewMonthRecomputesRowsWhoseStartDoesNotMove() async {
        commit("/p/a")
        let clock = Clock(Self.local(3, 31))
        let m = await makeModel(.allTime, clock: clock)
        var expected = m.recomputations

        clock.now = Self.local(4, 1)
        await settle(m)
        expected.rows += 1
        expected.usage += 1
        XCTAssertEqual(m.recomputations, expected, "monthStart")
    }

    /// The token chart's streak is the day's: a new day re-reads it even when
    /// nothing the rows read has moved.
    func testANewDayRecomputesTheUsageOnly() async {
        commit("/p/a")
        let clock = Clock(Self.local(3, 15))
        let m = await makeModel(.allTime, clock: clock)
        var expected = m.recomputations

        clock.now = Self.local(3, 16)
        await settle(m)
        expected.usage += 1
        XCTAssertEqual(m.recomputations, expected, "day")
    }

    /// A credit cap moves the week tab to the credit cycle, and the money per
    /// point follows the exchange rate.
    func testTheCreditAllowanceAndItsPointValueRecomputeRows() async throws {
        commit("/p/a")
        var credit = account!
        credit.creditLimit = 1_000
        let clock = Clock(Self.local(3, 15))
        let m = await makeModel(.today, clock: clock, account: credit)
        var expected = m.recomputations
        let samples = store.writes().samples

        m.observe([ProviderSnapshot(id: credit.id, displayName: "T", glyph: .third, fidelity: .official,
                                    status: .ok, windows: [LimitWindow(id: "credits", label: "Credits", usedFraction: 0.1)],
                                    headlineID: "credits")])
        XCTAssertEqual(m.allowance, .credits)
        let deadline = Date().addingTimeInterval(5)
        while store.writes().samples == samples, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        await settle(m)
        expected.rows += 1
        XCTAssertEqual(m.recomputations, expected, "allowance")

        price = Pricer(prices: price.prices, rate: 2)
        await settle(m)
        expected.rows += 1
        XCTAssertEqual(m.recomputations, expected, "creditPoint and monthlyLocal follow the rate")
    }

    // MARK: (4) same results as recomputing every time

    func testSkippingGivesTheSameResultsAsAFreshModelOnEveryRange() async {
        let start = Date().timeIntervalSince1970
        commit("/p/a", agoSeconds: 30)
        commit("/p/b", output: 3_000, agoSeconds: 20)
        let m = await makeModel(.today)

        func compareAllRanges(_ step: String) async {
            for range in CostRange.allCases {
                m.range = range
                await settle(m)
                await settle(m)
                let fresh = await makeModel(range)
                XCTAssertEqual(m.rows, fresh.rows, "\(step) \(range)")
                XCTAssertEqual(m.state, fresh.state, "\(step) \(range)")
                XCTAssertEqual(m.tokenUsage, fresh.tokenUsage, "\(step) \(range)")
            }
        }

        await compareAllRanges("turns")
        store.recordSample(window: .weekly, pct: 10, resetsAt: Date(timeIntervalSince1970: start + 86_400))
        store.recordSample(window: .session, pct: 5, resetsAt: Date(timeIntervalSince1970: start + 3_600))
        await compareAllRanges("first samples")
        commit("/p/c", output: 2_000, agoSeconds: 1)
        store.recordSample(window: .weekly, pct: 25, resetsAt: Date(timeIntervalSince1970: start + 86_400))
        store.recordSample(window: .session, pct: 12, resetsAt: Date(timeIntervalSince1970: start + 3_600))
        await compareAllRanges("attributed")
        price = Self.pricer(output: 75)
        await compareAllRanges("price")
    }

    // MARK: (5) no republishing of equal results

    func testEqualResultsAreNotRepublished() async {
        commit("/p/a")
        let m = await makeModel(.today)
        var published = 0
        let subs = [
            m.$rows.dropFirst().sink { _ in published += 1 },
            m.$tokenUsage.dropFirst().sink { _ in published += 1 },
            m.$state.dropFirst().sink { _ in published += 1 },
        ]
        defer { subs.forEach { $0.cancel() } }
        let before = m.recomputations

        // Recomputes the rows (a write they could depend on), but "today" is a
        // share of the turns, so the result is the same.
        store.recordSample(window: .weekly, pct: 10)
        await settle(m)
        XCTAssertEqual(m.recomputations.rows, before.rows + 1)
        XCTAssertEqual(published, 0)
    }
}

/// The test host is a running Codenotch; the cost models must not pick up the
/// developer's own accounts and transcripts there.
@MainActor
final class CostModelsUnderTestTests: XCTestCase {
    func testNoModelIsBuiltFromThisMachinesAccounts() {
        XCTAssertFalse(CostModels.isEnabled)
        XCTAssertNil(CostModels.model(for: "claude"))
        XCTAssertNil(CostModels.model(for: "codex"))
        for account in CostAccountStore.shared.accounts {
            XCTAssertNil(CostModels.model(for: account.id), account.id)
        }
        XCTAssertTrue(CostModels.all.isEmpty)
    }
}
