import Foundation
import Testing
@testable import Dusk

/// When the supporter prompt may show: first ask, dismissal backoff, tip
/// snooze, active-subscription suppression and resuming after a lapse.
@Suite("Supporter prompt schedule")
struct SupporterPromptScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * day) }

    /// A long-time user who qualifies for a prompt unless a test changes that.
    private func state(
        promptCount: Int = 0,
        lastPromptDaysAgo: Double? = nil,
        usageSincePrompt: Int = 20,
        active: Bool = false,
        expirationDaysAgo: Double? = nil,
        tipDaysAgo: Double? = nil
    ) -> SupporterPromptSchedule.State {
        SupporterPromptSchedule.State(
            firstLaunchDate: ago(1000),
            usageDayCount: 200,
            promptCount: promptCount,
            lastPromptDate: lastPromptDaysAgo.map(ago),
            lastPromptUsageDayCount: lastPromptDaysAgo == nil ? 0 : 200 - usageSincePrompt,
            hasActiveSubscription: active,
            lastSubscriptionExpiration: expirationDaysAgo.map(ago),
            lastTipDate: tipDaysAgo.map(ago)
        )
    }

    private func shows(_ state: SupporterPromptSchedule.State) -> Bool {
        SupporterPromptSchedule.shouldShow(state, now: now, calendar: calendar)
    }

    @Test func firstPromptNeedsDaysAndUsage() {
        var fresh = state()
        fresh.firstLaunchDate = ago(6)
        #expect(!shows(fresh))
        fresh.firstLaunchDate = ago(7)
        fresh.usageDayCount = 2
        #expect(!shows(fresh))
        fresh.usageDayCount = 3
        #expect(shows(fresh))
    }

    @Test func dismissalGapsGrowThenCapAtSixMonths() {
        #expect(SupporterPromptSchedule.dismissalGapDays == [60, 120, 180])
        for (count, gap) in [(1, 60), (2, 120), (3, 180), (4, 180), (12, 180)] {
            #expect(SupporterPromptSchedule.gapDays(afterPromptCount: count) == gap)
            #expect(!shows(state(promptCount: count, lastPromptDaysAgo: Double(gap - 1))))
            #expect(shows(state(promptCount: count, lastPromptDaysAgo: Double(gap))))
        }
    }

    @Test func laterPromptsNeedUsageSinceThePreviousOne() {
        #expect(!shows(state(promptCount: 1, lastPromptDaysAgo: 400, usageSincePrompt: 4)))
        #expect(shows(state(promptCount: 1, lastPromptDaysAgo: 400, usageSincePrompt: 5)))
    }

    @Test func tipSnoozesForAYearFromThePurchase() {
        #expect(!shows(state(tipDaysAgo: 0)))
        #expect(!shows(state(tipDaysAgo: 364)))
        #expect(shows(state(tipDaysAgo: 365)))
        // The dismissal gap still applies on top of the snooze.
        #expect(!shows(state(promptCount: 2, lastPromptDaysAgo: 100, tipDaysAgo: 400)))
    }

    @Test func activeSubscriptionNeverShows() {
        #expect(!shows(state(active: true)))
        #expect(!shows(state(promptCount: 5, lastPromptDaysAgo: 900, active: true, tipDaysAgo: 900)))
        // A cached period that hasn't ended counts as active (launch, before
        // StoreKit answers).
        #expect(!shows(state(expirationDaysAgo: -10)))
    }

    @Test func lapseResumesAfterAGracePeriod() {
        #expect(!shows(state(expirationDaysAgo: 0)))
        #expect(!shows(state(expirationDaysAgo: 29)))
        #expect(shows(state(expirationDaysAgo: 30)))
        // Then the normal gaps: a prompt 50 days ago (after prompt 1) waits.
        #expect(!shows(state(promptCount: 1, lastPromptDaysAgo: 50, expirationDaysAgo: 40)))
        #expect(shows(state(promptCount: 1, lastPromptDaysAgo: 70, expirationDaysAgo: 40)))
    }
}

/// The store feeds the schedule from cached, monotonic purchase evidence.
@Suite("Supporter prompt inputs")
@MainActor
struct SupporterPromptInputTests {
    @Test func tipDateIsCachedAndOnlyMovesForward() {
        let suite = "SupporterPromptInputTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()

        let store = SupporterStore(defaults: defaults)
        var entitlements = SupporterEntitlements()
        entitlements.historyWasEmpty = false
        entitlements.hasAnySupport = true
        entitlements.latestTipPurchase = now
        store.apply(entitlements)
        #expect(store.lastTipDate == now)

        // An empty read (offline) keeps the cached date.
        store.apply(SupporterEntitlements())
        #expect(store.lastTipDate == now)
        #expect(SupporterStore(defaults: defaults).lastTipDate == now)
    }

    @Test func historyResolvesTheLatestTip() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tips = [-200.0, -20].map { days in
            SupporterTransactionRecord(
                productID: SupporterProduct.tipCoffee.rawValue,
                originalPurchaseDate: now.addingTimeInterval(days * 86_400)
            )
        }
        let result = SupporterEntitlements.resolve(current: [], history: tips, now: now)
        #expect(result.latestTipPurchase == now.addingTimeInterval(-20 * 86_400))
    }
}
