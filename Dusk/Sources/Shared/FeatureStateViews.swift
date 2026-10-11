import SwiftUI

struct FeatureLoadingView: View {
    var body: some View {
        ProgressView()
    }
}

struct FeatureEmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(DuskFont.glyphLarge(ios: .largeTitle))
                .foregroundStyle(Color.duskTextSecondary)

            Text(title)
                .duskFont(tvOnly: DuskFont.TV.rowTitle)
                .foregroundStyle(Color.duskTextSecondary)

            if let message, !message.isEmpty {
                Text(message)
                    .font(DuskFont.caption(ios: .subheadline))
                    .foregroundStyle(Color.duskTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct FeatureErrorView: View {
    @Environment(PlexService.self) private var plexService

    let message: String
    let retryTitle: String
    let retryAction: () -> Void

    init(
        message: String,
        retryTitle: String = "Retry",
        retryAction: @escaping () -> Void
    ) {
        self.message = message
        self.retryTitle = retryTitle
        self.retryAction = retryAction
    }

    private var requiresSignIn: Bool {
        AuthenticationFailure.requiresReauthentication(message: message)
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(DuskFont.glyphLarge(ios: .largeTitle))
                .foregroundStyle(Color.duskTextSecondary)

            Text(message)
                .duskFont(tvOnly: DuskFont.TV.rowTitle)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            FeaturePrimaryButton(title: requiresSignIn ? "Sign In" : retryTitle) {
                if requiresSignIn {
                    AuthenticationFailure.beginReauthentication(plexService: plexService)
                } else {
                    retryAction()
                }
            }
        }
    }
}

/// The single action of an error or empty state, such as Retry or Sign In.
/// Same neutral glass as the detail pages' Play button.
struct FeaturePrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DuskFont.buttonLabel(ios: .headline))
                .padding(.horizontal, 12)
                #if !os(tvOS)
                .foregroundStyle(Color.duskPrimaryActionLabel)
                #endif
        }
        .detailHeroNativePrimaryButtonStyle()
    }
}

/// Shared detection and recovery for a dead Plex account session.
/// View models store `localizedDescription`, so message matching is the
/// feature-layer signal; typed errors use `requiresReauthentication` directly.
enum AuthenticationFailure {
    static func requiresReauthentication(message: String) -> Bool {
        message == PlexServiceError.unauthorized.errorDescription
            || message == PlexServiceError.notAuthenticated.errorDescription
            || message == PlaybackError.unauthorized.errorDescription
    }

    @MainActor
    static func beginReauthentication(
        plexService: PlexService,
        playback: PlaybackCoordinator? = nil
    ) {
        playback?.onPlayerDismissed()
        plexService.signOut()
    }
}
