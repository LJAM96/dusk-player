import SwiftUI

#if os(tvOS)
import UIKit

extension EnvironmentValues {
    @Entry var tvPlaybackFocusRestoration: TVPlaybackFocusRestoration? = nil
    @Entry var tvPlaybackFocusScope: [AnyHashable] = []
}

/// Own the shell's focus preference, including the tab bar. A background
/// representable is a sibling of the focusable controls and cannot influence
/// the default focus chain of the hosting/tab controllers.
struct TVPlaybackFocusHost<Content: View>: UIViewControllerRepresentable {
    let restoration: TVPlaybackFocusRestoration
    let isPlayerPresented: () -> Bool
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> TVPlaybackFocusHostingController {
        restoration.isPlayerPresented = isPlayerPresented
        return TVPlaybackFocusHostingController(
            rootView: AnyView(content().environment(\.self, context.environment)),
            restoration: restoration
        )
    }

    func updateUIViewController(_ controller: TVPlaybackFocusHostingController, context: Context) {
        restoration.isPlayerPresented = isPlayerPresented
        controller.rootView = AnyView(content().environment(\.self, context.environment))
        restoration.attach(host: controller, window: controller.viewIfLoaded?.window)
    }

    static func dismantleUIViewController(_ controller: TVPlaybackFocusHostingController, coordinator: ()) {
        controller.restoration.detach(host: controller)
    }
}

final class TVPlaybackFocusHostingController: UIHostingController<AnyView> {
    let restoration: TVPlaybackFocusRestoration

    init(rootView: AnyView, restoration: TVPlaybackFocusRestoration) {
        self.restoration = restoration
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:restoration:)") }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        if let window = viewIfLoaded?.window, let target = restoration.preferredEnvironment(in: window) {
            return [target]
        }
        return super.preferredFocusEnvironments
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if restoration.shouldBlockAutomaticTabFocus(context) { return false }
        return super.shouldUpdateFocus(in: context)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restoration.attach(host: self, window: view.window)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        restoration.attach(host: self, window: view.window)
    }
}

private struct TVPlaybackFocusTarget: ViewModifier {
    let controlID: AnyHashable
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content.focused($isFocused)
            .tvPlaybackFocusTarget(controlID, focus: $isFocused)
    }
}

private struct TVPlaybackFocusRegistration: ViewModifier {
    let controlID: AnyHashable
    let setFocused: (Bool) -> Void
    let isFocused: () -> Bool
    @Environment(\.tvPlaybackFocusRestoration) private var restoration
    @Environment(\.tvPlaybackFocusScope) private var scope
    @State private var token = UUID()

    private var id: TVPlaybackFocusRestoration.TargetID {
        .init(scope: scope, control: controlID)
    }

    func body(content: Content) -> some View {
        content
            .onAppear { register() }
            .onDisappear { restoration?.unregisterTarget(id, token: token) }
            .onChange(of: id) { oldID, _ in
                restoration?.unregisterTarget(oldID, token: token)
                register()
            }
            .onChange(of: isFocused(), initial: true) { _, focused in
                guard focused else { return }
                register()
                restoration?.rememberTarget(id)
            }
    }

    private func register() {
        restoration?.registerTarget(id, token: token, setFocused: setFocused, isFocused: isFocused)
    }
}
#endif

extension View {
    /// Reuse an existing binding: adding another `.focused` to a control can
    /// replace the focus binding its card/hero already depends on.
    @ViewBuilder
    func tvPlaybackFocusTarget<ID: Hashable>(_ id: ID, focus: FocusState<Bool>.Binding) -> some View {
        #if os(tvOS)
        modifier(TVPlaybackFocusRegistration(controlID: AnyHashable(id), setFocused: { focus.wrappedValue = $0 }, isFocused: { focus.wrappedValue }))
        #else
        self
        #endif
    }

    @ViewBuilder
    func tvPlaybackFocusTarget<ID: Hashable, Target: Hashable>(_ id: ID, focus: FocusState<Target?>.Binding, equals target: Target) -> some View {
        #if os(tvOS)
        modifier(TVPlaybackFocusRegistration(controlID: AnyHashable(id), setFocused: { focus.wrappedValue = $0 ? target : nil }, isFocused: { focus.wrappedValue == target }))
        #else
        self
        #endif
    }

    /// Use media/control identity, not a UIKit object or a newly allocated UUID:
    /// the same control can re-register after a window or view reconstruction.
    @ViewBuilder
    func tvPlaybackFocusTarget<ID: Hashable>(_ id: ID) -> some View {
        #if os(tvOS)
        modifier(TVPlaybackFocusTarget(controlID: AnyHashable(id)))
        #else
        self
        #endif
    }

    @ViewBuilder
    func tvPlaybackFocusScope<ID: Hashable>(_ id: ID) -> some View {
        #if os(tvOS)
        transformEnvironment(\.tvPlaybackFocusScope) { $0.append(AnyHashable(id)) }
        #else
        self
        #endif
    }
}
