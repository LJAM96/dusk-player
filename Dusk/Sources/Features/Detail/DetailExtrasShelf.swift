import SwiftUI

/// Loads the extras of one movie, show, season, or episode.
@MainActor
@Observable
final class DetailExtrasModel {
    private(set) var extras: [PlexExtra] = []

    @ObservationIgnored private var loadedID: PlexItemID?

    /// - Parameter delay: waited before the request, so a row that follows
    ///   focus (the tvOS episode row) does not fetch for every card zapped past.
    func load(itemID: PlexItemID?, plexService: PlexService, delay: Duration = .zero) async {
        guard itemID != loadedID else { return }
        // Another title's extras must not linger while this one's load.
        loadedID = nil
        extras = []
        guard let itemID else { return }

        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        guard !Task.isCancelled else { return }

        // Offline or unreachable: no row, same as a title without extras, and
        // the next appearance asks again.
        guard let loaded = try? await plexService.getExtras(
            ratingKey: itemID.ratingKey,
            serverID: itemID.serverID
        ), !Task.isCancelled else { return }
        loadedID = itemID
        extras = loaded
    }

    func subtitle(for item: PlexItem) -> String? {
        extras.first { $0.id == item.id }?.cardSubtitle
    }
}

/// The 16:9 "Extras" row of a detail page: the title's trailers, featurettes,
/// deleted scenes, … Selecting one plays it through the normal clip path. The
/// row is absent when the title has no extras.
struct DetailExtrasShelf: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback

    let itemID: PlexItemID?
    var title: String = "Extras"
    /// What the extras belong to; the player's loading screen shows it under
    /// the extra's own title.
    var ownerTitle: String?
    var topPadding: CGFloat = 40
    var bottomPadding: CGFloat = 0
    var loadDelay: Duration = .zero

    @State private var model = DetailExtrasModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.extras.isEmpty {
                PlexItemActionCarouselSection(
                    title: title,
                    items: model.extras.map(\.item),
                    action: play,
                    posterWidth: DuskPosterMetrics.videoCarouselWidth,
                    imageAspectRatio: 16.0 / 9.0,
                    horizontalPadding: DuskPosterMetrics.detailHorizontalPadding,
                    subtitle: { model.subtitle(for: $0) },
                    posterURL: { item, width, height in
                        item.posterImageURL(plexService: plexService, width: width, height: height)
                    },
                    progress: { $0.posterProgress }
                ) { _ in
                    EmptyView()
                }
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
                #if os(tvOS)
                .focusSection()
                #endif
            }
        }
        .task(id: itemID) {
            await model.load(itemID: itemID, plexService: plexService, delay: loadDelay)
        }
    }

    private func play(_ item: PlexItem) {
        let placeholder = PlaybackPlaceholder(
            title: item.title,
            subtitle: ownerTitle ?? model.subtitle(for: item),
            posterPath: item.preferredPosterPath,
            backdropPath: item.art ?? item.thumb,
            serverID: item.serverID
        )
        Task {
            await playback.play(
                id: item.id,
                resumeOffsetMilliseconds: item.viewOffset,
                resumeOffsetDurationMilliseconds: item.duration,
                placeholder: placeholder
            )
        }
    }
}
