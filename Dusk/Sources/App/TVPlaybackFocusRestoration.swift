#if os(tvOS)
import AVKit
import SwiftUI
import OSLog
import UIKit

/// Weak references preserve UIKit and SwiftUI focus items without keeping a
/// dismissed page alive. Stop at the page controller: fallback must never reach
/// the tab bar's default focus environment.
@MainActor
final class TVPlaybackFocusSnapshot {
    private final class Entry {
        weak var environment: (any UIFocusEnvironment)?
        let isOriginalItem: Bool

        init(_ environment: any UIFocusEnvironment, isOriginalItem: Bool) {
            self.environment = environment
            self.isOriginalItem = isOriginalItem
        }
    }

    private let entries: [Entry]

    init(item: any UIFocusItem) {
        var entries = [Entry(item, isOriginalItem: true)]
        var parent = item.parentFocusEnvironment
        while let environment = parent {
            // A snapshot from a navigation control must not restore into the
            // tab bar, even if it was focused when playback began via Siri.
            if environment is UITabBar || environment is UITabBarController || environment is UIWindow {
                break
            }
            entries.append(Entry(environment, isOriginalItem: false))
            if environment is UIViewController { break }
            parent = environment.parentFocusEnvironment
        }
        self.entries = entries
    }

    func preferredEnvironment(where isAvailable: (any UIFocusEnvironment) -> Bool) -> (any UIFocusEnvironment)? {
        for entry in entries {
            guard let environment = entry.environment, isAvailable(environment) else { continue }
            if entry.isOriginalItem, let item = environment as? any UIFocusItem, !item.canBecomeFocused {
                continue
            }
            return environment
        }
        return nil
    }
}

/// Restoration is an intent, not a deadline. Display/scene/layout events can
/// arrive long after dismissal, including after an initially successful focus.
struct TVPlaybackFocusRestorationState {
    enum Phase { case idle, playing, restoring }
    private(set) var phase: Phase = .idle
    var isDisplaySwitching = false
    var isSceneActive = true
    var canRestore: Bool { phase == .restoring && !isDisplaySwitching && isSceneActive }

    mutating func playerWillPresent() { phase = .playing }
    mutating func playerDidDismiss() { if phase == .playing { phase = .restoring } }
    mutating func userDidInteract() { if phase == .restoring { phase = .idle } }
    mutating func reset() { self = Self() }
}

@MainActor
final class TVPlaybackFocusRestoration: NSObject {
    struct TargetID: Hashable {
        let scope: [AnyHashable]
        let control: AnyHashable
    }

    private struct Target {
        let token: UUID
        let setFocused: (Bool) -> Void
        let isFocused: () -> Bool
    }

    var isPlayerPresented: () -> Bool = { false }
    private(set) var state = TVPlaybackFocusRestorationState()
    private(set) var savedTargetID: TargetID?
    var isPreservingOrigin: Bool { state.phase != .idle }
    private weak var window: UIWindow?
    private weak var host: TVPlaybackFocusHostingController?
    private var rememberedFocus: TVPlaybackFocusSnapshot?
    private var playbackFocus: TVPlaybackFocusSnapshot?
    private var rememberedTargetID: TargetID?
    private var targets: [TargetID: Target] = [:]
    private var inputObserver: TVPlaybackFocusInputObserver?
    private var displayObservation: NSKeyValueObservation?
    private var isObserving = false
    private var hasScheduledRestore = false
    private var requestedTargetToken: UUID?
    private var generation = 0
    #if DEBUG
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dusk", category: "TVPlaybackFocus")
    #endif

    func attach(host: TVPlaybackFocusHostingController, window: UIWindow?) {
        self.host = host
        startObservingIfNeeded()
        guard let window else { return }
        if self.window !== window {
            // Rebind observers, NEVER reset the origin when UIKit replaces a
            // window or SwiftUI reconstructs its presenting controller.
            if let inputObserver { inputObserver.view?.removeGestureRecognizer(inputObserver) }
            displayObservation = nil
            requestedTargetToken = nil
            self.window = window
            let observer = TVPlaybackFocusInputObserver { [weak self] in self?.userDidInteract() }
            window.addGestureRecognizer(observer)
            inputObserver = observer
            observeDisplayManager(in: window)
            trace("window attached")
        }
        sceneActivationChanged(window.windowScene?.activationState == .foregroundActive)
        if !isPreservingOrigin { remember(window.windowScene?.focusSystem?.focusedItem) }
        scheduleRestore(reason: "host attached/layout")
    }

    func detach(host: TVPlaybackFocusHostingController) {
        guard self.host === host else { return }
        self.host = nil
        // The app owns the restoration intent. A representable dismantle or
        // window gap is not user navigation and must not discard it.
        trace("host detached; origin preserved")
    }

    func reset() {
        generation += 1
        state.reset()
        savedTargetID = nil
        rememberedTargetID = nil
        playbackFocus = nil
        rememberedFocus = nil
        targets.removeAll()
        requestedTargetToken = nil
        trace("profile/session reset")
    }

    func registerTarget(_ id: TargetID, token: UUID, setFocused: @escaping (Bool) -> Void, isFocused: @escaping () -> Bool) {
        if savedTargetID == id, targets[id]?.token != token { requestedTargetToken = nil }
        targets[id] = Target(token: token, setFocused: setFocused, isFocused: isFocused)
        if savedTargetID == id { scheduleRestore(reason: "saved SwiftUI target registered again") }
    }

    func unregisterTarget(_ id: TargetID, token: UUID) {
        guard targets[id]?.token == token else { return }
        targets[id] = nil
        // Keep the identity so a newly materialized copy can answer the intent.
        if savedTargetID == id { trace("saved SwiftUI target unregistered; identity preserved") }
    }

    func rememberTarget(_ id: TargetID) {
        guard !isPlayerPresented(), !isPreservingOrigin else { return }
        rememberedTargetID = id
        trace("SwiftUI content target remembered")
    }

    func playerWillPresent() {
        guard state.phase != .playing else { return }
        generation += 1
        playbackFocus = rememberedFocus
        savedTargetID = rememberedTargetID
        requestedTargetToken = nil
        state.playerWillPresent()
        trace("player presenting; origin frozen")
    }

    /// MainTabView calls this after teardown releases the display criteria.
    func playerDidDismiss() {
        state.playerDidDismiss()
        requestedTargetToken = nil
        trace("player dismissed")
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-DuskSimulateDisplayFocusReset") {
            simulateDelayedDisplayReturn()
        }
        #endif
        scheduleRestore(reason: "cover onDismiss")
    }

    func userDidInteract() {
        guard state.phase == .restoring else { return }
        generation += 1
        state.userDidInteract()
        savedTargetID = nil
        playbackFocus = nil
        requestedTargetToken = nil
        host?.setNeedsFocusUpdate()
        trace("remote/navigation input released focus preference")
    }

    func displaySwitchChanged(_ isSwitching: Bool) {
        state.isDisplaySwitching = isSwitching
        requestedTargetToken = nil
        trace(isSwitching ? "display switch began" : "display switch ended")
        if !isSwitching { scheduleRestore(reason: "display switch ended") }
    }

    func sceneActivationChanged(_ isActive: Bool) {
        let changed = state.isSceneActive != isActive
        state.isSceneActive = isActive
        if changed { requestedTargetToken = nil }
        if changed { trace(isActive ? "scene active" : "scene inactive") }
        if isActive { scheduleRestore(reason: "scene active") }
    }

    func preferredEnvironment(in window: UIWindow) -> (any UIFocusEnvironment)? {
        guard state.phase == .restoring else { return nil }
        return playbackFocus?.preferredEnvironment(where: { window.contains($0) })
            ?? selectedContentController(in: host)
    }

    func shouldBlockAutomaticTabFocus(_ context: UIFocusUpdateContext) -> Bool {
        guard state.phase == .restoring, context.focusHeading.isEmpty,
              !isPlayerPresented(), let item = context.nextFocusedItem,
              Self.isTabBar(item), let window,
              window.rootViewController?.presentedViewController == nil,
              preferredEnvironment(in: window) != nil else { return false }
        trace("blocked automatic tab-bar focus")
        scheduleRestore(reason: "tab-bar default focus rejected")
        return true
    }

    func scheduleRestore(reason: String) {
        guard state.canRestore, !hasScheduledRestore else { return }
        hasScheduledRestore = true
        let requestedGeneration = generation
        // Let SwiftUI install the new scene/layout/FocusState bindings first.
        // This is one deferred event response, with no timer or expiry window.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasScheduledRestore = false
            guard self.generation == requestedGeneration else {
                self.scheduleRestore(reason: "new restoration replaced queued request")
                return
            }
            self.restore(reason: reason)
        }
    }

    private func restore(reason: String) {
        guard state.canRestore, !isPlayerPresented(), let window, let host,
              host.viewIfLoaded?.window === window,
              window.isKeyWindow, window.windowScene?.activationState == .foregroundActive,
              window.rootViewController?.presentedViewController == nil else {
            trace("restore deferred: \(reason)")
            return
        }
        let focused = window.windowScene?.focusSystem?.focusedItem
        if let id = savedTargetID, let target = targets[id] {
            if target.isFocused(), let focused, host.contains(focused), !Self.isTabBar(focused) {
                requestedTargetToken = nil
                trace("SwiftUI origin focused: \(reason)")
                return
            }
            if requestedTargetToken != target.token {
                // Avoid a FocusState -> layout -> FocusState feedback loop if
                // the saved control is temporarily disabled or unrealized.
                requestedTargetToken = target.token
                let requestedGeneration = generation
                target.setFocused(false)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == requestedGeneration, self.state.canRestore,
                          let current = self.targets[id], current.token == target.token else { return }
                    current.setFocused(true)
                    self.trace("requested saved SwiftUI focus: \(reason)")
                }
            }
        }
        if let target = preferredEnvironment(in: window) {
            if let focused, focused === target || target.contains(focused) { return }
            trace("requesting hosting preference \(String(describing: type(of: target))): \(reason)")
            host.setNeedsFocusUpdate()
            window.windowScene?.focusSystem?.requestFocusUpdate(to: host)
            host.updateFocusIfNeeded()
            window.windowScene?.focusSystem?.updateFocusIfNeeded()
        } else {
            trace("no content target available: \(reason)")
        }
    }

    private func startObservingIfNeeded() {
        guard !isObserving else { return }
        isObserving = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(focusDidUpdate(_:)), name: UIFocusSystem.didUpdateNotification, object: nil)
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                     UIApplication.didBecomeActiveNotification, UIWindow.didBecomeKeyNotification,
                     UIScreen.modeDidChangeNotification] {
            center.addObserver(self, selector: #selector(lifecycleChanged(_:)), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(displayNotification(_:)), name: Notification.Name.AVDisplayManagerModeSwitchStart, object: nil)
        center.addObserver(self, selector: #selector(displayNotification(_:)), name: Notification.Name.AVDisplayManagerModeSwitchEnd, object: nil)
    }

    private func observeDisplayManager(in window: UIWindow) {
        #if !targetEnvironment(simulator)
        guard window.responds(to: NSSelectorFromString("avDisplayManager")) else {
            trace("AVDisplayManager category unavailable")
            return
        }
        let manager = window.avDisplayManager
        let windowID = ObjectIdentifier(window)
        state.isDisplaySwitching = manager.isDisplayModeSwitchInProgress
        displayObservation = manager.observe(\.isDisplayModeSwitchInProgress, options: [.new]) { [weak self] manager, _ in
            let isSwitching = manager.isDisplayModeSwitchInProgress
            Task { @MainActor [weak self] in
                guard let self, self.window.map(ObjectIdentifier.init) == windowID else { return }
                self.displaySwitchChanged(isSwitching)
            }
        }
        #endif
    }

    @objc private func displayNotification(_ notification: Notification) {
        guard let window, window.responds(to: NSSelectorFromString("avDisplayManager")),
              notification.object as AnyObject? === window.avDisplayManager else { return }
        displaySwitchChanged(notification.name == Notification.Name.AVDisplayManagerModeSwitchStart)
    }

    @objc private func lifecycleChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
        if let screen = notification.object as? UIScreen, screen !== window?.screen { return }
        if let newWindow = host?.viewIfLoaded?.window, let host { attach(host: host, window: newWindow) }
        if notification.name == UIScene.willDeactivateNotification {
            sceneActivationChanged(false)
        } else {
            sceneActivationChanged(window?.windowScene?.activationState == .foregroundActive)
            scheduleRestore(reason: "notification \(notification.name.rawValue)")
        }
    }

    @objc private func focusDidUpdate(_ notification: Notification) {
        guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext,
              let window else { return }
        if isPlayerPresented() { playerWillPresent(); return }
        if state.phase == .restoring {
            if context.nextFocusedItem == nil || context.nextFocusedItem.map(Self.isTabBar) == true {
                requestedTargetToken = nil
            }
            trace("focus update next=\(context.nextFocusedItem.map { String(describing: type(of: $0)) } ?? "nil") heading=\(context.focusHeading.rawValue)")
            scheduleRestore(reason: "automatic focus update")
        } else if state.phase == .idle, let item = context.nextFocusedItem, window.contains(item) {
            remember(item)
        }
    }

    private func remember(_ item: (any UIFocusItem)?) {
        guard let item, let host, host.contains(item), !Self.isTabBar(item) else { return }
        rememberedFocus = TVPlaybackFocusSnapshot(item: item)
        // An uninstrumented content control must not inherit the previous
        // control's semantic identity. Its UIKit snapshot is still restorable.
        if !targets.values.contains(where: { $0.isFocused() }) { rememberedTargetID = nil }
    }

    private static func isTabBar(_ item: any UIFocusEnvironment) -> Bool {
        var environment: (any UIFocusEnvironment)? = item
        while let current = environment {
            if current is UITabBar { return true }
            environment = current.parentFocusEnvironment
        }
        return false
    }

    private func selectedContentController(in controller: UIViewController?) -> UIViewController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs.selectedViewController }
        return controller.children.lazy.compactMap { self.selectedContentController(in: $0) }.first
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Opt-in reproduction without HDMI: defer the return for longer than the
    /// old eight-second window, then ask UIKit for tab-bar default focus.
    private func simulateDelayedDisplayReturn() {
        displaySwitchChanged(true)
        sceneActivationChanged(false)
        trace("DEBUG simulation: delaying display return by 12 seconds")
        let requestedGeneration = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.generation == requestedGeneration, self.state.phase == .restoring else { return }
            @MainActor func tabController(in controller: UIViewController) -> UITabBarController? {
                if let tab = controller as? UITabBarController { return tab }
                return controller.children.lazy.compactMap { tabController(in: $0) }.first
            }
            if let host = self.host, let tabs = tabController(in: host) {
                self.trace("DEBUG simulation: requesting late tab-bar default focus")
                self.window?.windowScene?.focusSystem?.requestFocusUpdate(to: tabs.tabBar)
                self.window?.windowScene?.focusSystem?.updateFocusIfNeeded()
            }
            self.sceneActivationChanged(true)
            self.displaySwitchChanged(false)
        }
    }
    #endif

    private func trace(_ message: String) {
        #if DEBUG
        logger.debug("\(message, privacy: .public); phase=\(String(describing: self.state.phase), privacy: .public) switching=\(self.state.isDisplaySwitching) active=\(self.state.isSceneActive) semantic=\(self.savedTargetID != nil) registered=\(self.targets.count) window=\(self.window != nil) host=\(self.host != nil)")
        #endif
    }
}

/// Observe presses/touch without consuming or delaying the remote's events.
private final class TVPlaybackFocusInputObserver: UIGestureRecognizer {
    private let onInput: () -> Void

    init(onInput: @escaping () -> Void) {
        self.onInput = onInput
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        onInput()
        state = .failed
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onInput()
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

#endif
