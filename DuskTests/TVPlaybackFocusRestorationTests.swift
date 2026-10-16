#if os(tvOS)
import Foundation
import Testing
import UIKit
@testable import Dusk

struct TVPlaybackFocusRestorationTimingTests {
    private func expectResult(_ result: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(result, sourceLocation: sourceLocation)
    }

    @Test func dismissalWaitsForDelayedSwitchAndFinalLayout() {
        var timing = TVPlaybackFocusRestorationTiming()
        timing.begin(at: 10)
        expectResult(!timing.shouldRestore(at: 10.1, isSwitching: false, isActive: true))
        expectResult(!timing.shouldRestore(at: 10.3, isSwitching: true, isActive: true))
        expectResult(!timing.shouldRestore(at: 12, isSwitching: true, isActive: true))
        expectResult(!timing.shouldRestore(at: 12.2, isSwitching: false, isActive: true))
        expectResult(timing.shouldRestore(at: 12.4, isSwitching: false, isActive: true))
        // A second mode/layout transition after the initial restoration.
        expectResult(!timing.shouldRestore(at: 13, isSwitching: true, isActive: true))
        expectResult(timing.shouldRestore(at: 13.4, isSwitching: false, isActive: true))
    }

    @Test func inactiveSceneAndNoModeSwitchBothSettle() {
        var timing = TVPlaybackFocusRestorationTiming()
        timing.begin(at: 10)
        expectResult(timing.shouldRestore(at: 10.4, isSwitching: false, isActive: true))
        expectResult(!timing.shouldRestore(at: 11, isSwitching: false, isActive: false))
        expectResult(!timing.shouldRestore(at: 11.2, isSwitching: false, isActive: true))
        expectResult(timing.shouldRestore(at: 11.4, isSwitching: false, isActive: true))
    }

    @Test func slowHDMISwitchStillRestoresAfterItFinishes() {
        var timing = TVPlaybackFocusRestorationTiming()
        timing.begin(at: 10)
        for time in stride(from: 10.1, through: 22, by: 0.1) {
            expectResult(!timing.shouldRestore(at: time, isSwitching: true, isActive: true))
        }
        expectResult(timing.shouldRestore(at: 22.5, isSwitching: false, isActive: true))
        expectResult(!timing.shouldRestore(at: 40, isSwitching: true, isActive: true))
        expectResult(timing.startedAt == nil)
    }

    @Test func userInputTimeoutAndNewPlaybackInvalidateOldRestoration() {
        var timing = TVPlaybackFocusRestorationTiming()
        timing.begin(at: 10)
        timing.cancel()
        expectResult(!timing.shouldRestore(at: 11, isSwitching: false, isActive: true))
        timing.begin(at: 20)
        expectResult(!timing.shouldRestore(
            at: 20 + TVPlaybackFocusRestorationTiming.maximumDuration,
            isSwitching: false, isActive: true
        ))
        expectResult(timing.startedAt == nil)
        timing.begin(at: 30)
        expectResult(!timing.shouldRestore(at: 30.1, isSwitching: false, isActive: true))
    }
}

@MainActor
struct TVPlaybackFocusSnapshotTests {
    private final class Item: UIView {
        var acceptsFocus = true
        override var canBecomeFocused: Bool { acceptsFocus }
    }

    @Test func restoresExactItemAndFallsBackWhenItIsUnavailable() {
        let page = UIViewController()
        let row = UIView()
        let item = Item()
        page.view.addSubview(row)
        row.addSubview(item)
        let snapshot = TVPlaybackFocusSnapshot(item: item)
        #expect(snapshot.preferredEnvironment(where: { _ in true }) === item)
        item.acceptsFocus = false
        #expect(snapshot.preferredEnvironment(where: { _ in true }) === row)
        // Detached environments must not receive focus, even if still alive.
        #expect(snapshot.preferredEnvironment(where: { $0 === page }) === page)
    }

    @Test func removedItemIsNotRetainedAndPageBoundaryExcludesTabBar() {
        let tab = UITabBarController()
        let page = UIViewController()
        tab.setViewControllers([page], animated: false)
        let item = Item()
        page.view.addSubview(item)
        let snapshot = TVPlaybackFocusSnapshot(item: item)
        #expect(snapshot.preferredEnvironment(where: { $0 === tab }) == nil)

        var removedSnapshot: TVPlaybackFocusSnapshot?
        weak var removedItem: Item?
        autoreleasepool {
            let temporary = Item()
            removedItem = temporary
            page.view.addSubview(temporary)
            removedSnapshot = TVPlaybackFocusSnapshot(item: temporary)
            temporary.removeFromSuperview()
        }
        #expect(removedItem == nil)
        #expect(removedSnapshot?.preferredEnvironment(where: { $0 === page.view }) === page.view)
    }
}
#endif
