#if os(tvOS)
import AVKit
import SwiftUI
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

/// A quiet interval handles the delayed start of a mode switch as well as the
/// layout/focus passes after it finishes. Keep watching briefly after success:
/// an HDMI mode change can reset focus a second time. Never fight remote input.
struct TVPlaybackFocusRestorationTiming {
    private(set) var startedAt: TimeInterval?
    private var stableSince: TimeInterval = 0
    static let maximumDuration: TimeInterval = 8
    static let maximumWaitDuration: TimeInterval = 30
    static let settleDuration: TimeInterval = 0.35

    mutating func begin(at time: TimeInterval) {
        startedAt = time
        stableSince = time
    }

    mutating func cancel() {
        startedAt = nil
    }

    mutating func shouldRestore(at time: TimeInterval, isSwitching: Bool, isActive: Bool) -> Bool {
        guard let startedAt else { return false }
        guard time - startedAt < Self.maximumWaitDuration else {
            cancel()
            return false
        }
        if isSwitching || !isActive {
            stableSince = time
            return false
        }
        guard time - stableSince < Self.maximumDuration else {
            cancel()
            return false
        }
        return time - stableSince >= Self.settleDuration
    }
}

@MainActor
final class TVPlaybackFocusRestoration: NSObject {
    var isPlayerPresented: () -> Bool = { false }

    private weak var window: UIWindow?
    private var rememberedFocus: TVPlaybackFocusSnapshot?
    private var playbackFocus: TVPlaybackFocusSnapshot?
    private var hasPlaybackSession = false
    private var timing = TVPlaybackFocusRestorationTiming()
    private var restorationTask: Task<Void, Never>?
    private var inputObserver: TVPlaybackFocusInputObserver?

    func attach(to window: UIWindow?) {
        // A full-screen cover can temporarily remove its presenting view from
        // the window. Keep the snapshot and window observer through that gap.
        guard let window else { return }
        guard self.window !== window else { return }
        detach()
        self.window = window
        NotificationCenter.default.addObserver(
            self, selector: #selector(focusDidUpdate(_:)), name: UIFocusSystem.didUpdateNotification, object: nil
        )
        let observer = TVPlaybackFocusInputObserver { [weak self] in self?.cancelRestoration() }
        window.addGestureRecognizer(observer)
        inputObserver = observer
        remember(window.windowScene?.focusSystem?.focusedItem)
    }

    func detach() {
        cancelRestoration()
        NotificationCenter.default.removeObserver(self)
        if let inputObserver { inputObserver.view?.removeGestureRecognizer(inputObserver) }
        inputObserver = nil
        window = nil
        rememberedFocus = nil
        playbackFocus = nil
        hasPlaybackSession = false
    }

    func playerWillPresent() {
        guard !hasPlaybackSession else { return }
        cancelRestoration()
        playbackFocus = rememberedFocus
        hasPlaybackSession = true
    }

    /// Called from the cover's onDismiss, AFTER onPlayerDismissed has released
    /// display criteria. showPlayer becoming false is too early to restore.
    func playerDidDismiss() {
        guard hasPlaybackSession else { return }
        hasPlaybackSession = false
        guard playbackFocus != nil else { return }
        timing.begin(at: ProcessInfo.processInfo.systemUptime)
        restorationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.restoreIfReady()
                guard self.timing.startedAt != nil else { return }
            }
        }
    }

    private func cancelRestoration() {
        timing.cancel()
        restorationTask?.cancel()
        restorationTask = nil
        // Player presses (including the exit press) must not erase the origin.
        if !hasPlaybackSession { playbackFocus = nil }
    }

    @objc private func focusDidUpdate(_ notification: Notification) {
        guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext,
              let window,
              let item = context.nextFocusedItem,
              window.contains(item) else { return }

        // Read the binding directly: UIKit can move focus into the cover before
        // SwiftUI delivers onChange(showPlayer). Freeze the last content item.
        if isPlayerPresented() {
            playerWillPresent()
            return
        }
        if !context.focusHeading.isEmpty { cancelRestoration() }
        guard !hasPlaybackSession, timing.startedAt == nil else { return }
        remember(item)
    }

    private func remember(_ item: (any UIFocusItem)?) {
        guard let item, let window, window.contains(item) else { return }
        var environment: (any UIFocusEnvironment)? = item
        while let current = environment {
            if current is UITabBar { return }
            environment = current.parentFocusEnvironment
        }
        rememberedFocus = TVPlaybackFocusSnapshot(item: item)
    }

    private func restoreIfReady() {
        guard !isPlayerPresented() else {
            playerWillPresent()
            return
        }
        guard let window else { cancelRestoration(); return }
        let isSwitching: Bool
        #if targetEnvironment(simulator)
        isSwitching = false
        #else
        // Match DisplayModeMatcher's guarded AVKit category lookup.
        isSwitching = window.responds(to: NSSelectorFromString("avDisplayManager"))
            && window.avDisplayManager.isDisplayModeSwitchInProgress
        #endif
        guard timing.shouldRestore(
            at: ProcessInfo.processInfo.systemUptime,
            isSwitching: isSwitching,
            isActive: window.isKeyWindow && window.windowScene?.activationState == .foregroundActive
        ) else {
            if timing.startedAt == nil { cancelRestoration() }
            return
        }
        // A sheet opened after playback owns focus until it goes away.
        guard window.rootViewController?.presentedViewController == nil,
              let focusSystem = window.windowScene?.focusSystem,
              let target = playbackFocus?.preferredEnvironment(where: {
                  window.contains($0)
              }) else { return }
        if let focused = focusSystem.focusedItem,
           focused === target || target.contains(focused) { return }
        focusSystem.requestFocusUpdate(to: target)
        focusSystem.updateFocusIfNeeded()
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

struct TVPlaybackFocusAttachment: UIViewRepresentable {
    let restoration: TVPlaybackFocusRestoration
    let isPlayerPresented: () -> Bool

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.restoration = restoration
        restoration.isPlayerPresented = isPlayerPresented
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        restoration.isPlayerPresented = isPlayerPresented
        restoration.attach(to: uiView.window)
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: ()) {
        uiView.restoration?.detach()
    }

    final class AttachmentView: UIView {
        weak var restoration: TVPlaybackFocusRestoration?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            restoration?.attach(to: window)
        }
    }
}
#endif
