#if os(tvOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Dusk

struct TVPlaybackFocusRestorationStateTests {
    @Test func delayedAndRepeatedDisplaySwitchesDoNotExpireRestoration() {
        var state = TVPlaybackFocusRestorationState()
        state.playerWillPresent()
        state.playerDidDismiss()
        #expect(state.canRestore)
        // Unlike the previous timer, any number of events, arbitrarily far
        // apart, keeps the same restoration intent until actual remote input.
        for _ in 0..<100 {
            state.isDisplaySwitching = true
            state.isSceneActive = false
            #expect(!state.canRestore)
            state.isDisplaySwitching = false
            #expect(!state.canRestore)
            state.isSceneActive = true
            #expect(state.canRestore)
        }
        state.userDidInteract()
        state.isDisplaySwitching = true
        state.isDisplaySwitching = false
        #expect(!state.canRestore)
    }

    @Test func exitPressDuringPlaybackDoesNotEraseTheOrigin() {
        var state = TVPlaybackFocusRestorationState()
        state.playerWillPresent()
        state.userDidInteract()
        #expect(state.phase == .playing)
        state.playerDidDismiss()
        #expect(state.canRestore)
        state.playerWillPresent()
        #expect(!state.canRestore)
    }
}

@MainActor
struct TVPlaybackFocusReconstructionTests {
    private final class AutomaticFocusUpdate: UIFocusUpdateContext {
        var destination: (any UIFocusItem)?
        override var nextFocusedItem: (any UIFocusItem)? { destination }
        override var focusHeading: UIFocusHeading { [] }
    }

    @Test func hostingPreferenceRejectsTabDefaultUntilRemoteInputReleasesIt() {
        let restoration = TVPlaybackFocusRestoration()
        let host = TVPlaybackFocusHostingController(rootView: AnyView(EmptyView()), restoration: restoration)
        let tabs = UITabBarController()
        let content = UIViewController()
        tabs.setViewControllers([content], animated: false)
        host.addChild(tabs)
        host.view.addSubview(tabs.view)
        tabs.didMove(toParent: host)
        let window = UIWindow()
        window.rootViewController = host
        window.addSubview(host.view)
        restoration.attach(host: host, window: window)
        restoration.playerWillPresent()
        restoration.playerDidDismiss()

        // UIKit's default destination is a synthetic item inside the real bar.
        let tabItem = UIView()
        tabs.tabBar.addSubview(tabItem)
        let context = AutomaticFocusUpdate()
        context.destination = tabItem
        #expect(host.preferredFocusEnvironments.first === content)
        #expect(restoration.shouldBlockAutomaticTabFocus(context))
        #expect(!host.shouldUpdateFocus(in: context))
        restoration.userDidInteract()
        #expect(!restoration.shouldBlockAutomaticTabFocus(context))
    }

    @Test func sceneWindowAndSwiftUITargetReplacementPreserveTheSameOrigin() {
        let restoration = TVPlaybackFocusRestoration()
        let id = TVPlaybackFocusRestoration.TargetID(scope: [AnyHashable("Home"), AnyHashable("Continue Watching")], control: AnyHashable("server:item"))
        let oldToken = UUID()
        restoration.registerTarget(id, token: oldToken, setFocused: { _ in }, isFocused: { true })
        restoration.rememberTarget(id)
        restoration.playerWillPresent()
        restoration.userDidInteract() // The Back press that closes the player.
        restoration.displaySwitchChanged(true)
        restoration.playerDidDismiss()
        restoration.sceneActivationChanged(false)

        let oldHost = TVPlaybackFocusHostingController(rootView: AnyView(EmptyView()), restoration: restoration)
        let oldWindow = UIWindow()
        oldWindow.rootViewController = oldHost
        restoration.attach(host: oldHost, window: oldWindow)
        restoration.unregisterTarget(id, token: oldToken)
        restoration.detach(host: oldHost)
        oldWindow.rootViewController = nil
        #expect(restoration.savedTargetID == id)

        let newHost = TVPlaybackFocusHostingController(rootView: AnyView(EmptyView()), restoration: restoration)
        let newWindow = UIWindow()
        newWindow.rootViewController = newHost
        restoration.attach(host: newHost, window: newWindow)
        restoration.registerTarget(id, token: UUID(), setFocused: { _ in }, isFocused: { false })
        restoration.displaySwitchChanged(false)
        restoration.sceneActivationChanged(true)
        #expect(restoration.state.canRestore)
        #expect(restoration.savedTargetID == id)
        restoration.userDidInteract()
        #expect(!restoration.state.canRestore)
        #expect(restoration.savedTargetID == nil)
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
