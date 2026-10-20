#if os(tvOS)
import SwiftUI

/// Home on tvOS: the featured hero (Continue Watching) over the shelves. See
/// `TVFeaturedHeroPage` for the hero and how the page moves.
struct HomeTVView: View {
    @Binding var path: NavigationPath

    let viewModel: HomeViewModel
    /// Enabled servers that are currently unreachable. Only used for the quiet
    /// inline note; Home never names the server a row came from, because with
    /// every server merged into one screen that would be noise.
    let offlineServerNames: [String]
    let recentlyAddedInlineItemLimit: Int
    let heroSelectionResetRevision: Int
    let liveTVViewModel: LiveTVViewModel
    let showsLiveTV: Bool
    /// Reports whether the page is scrolled away from its top. See
    /// `HomeView.isScrolledOffTop`.
    @Binding var isScrolledOffTop: Bool
    let scrollToTopRevision: Int
    let playLiveTV: (PlexLiveChannel, PlexLiveProgram, PlexLiveTVLineup) -> Void
    let play: (PlexItem) -> Void

    var body: some View {
        TVFeaturedHeroPage(
            rowTitle: "Continue Watching",
            items: viewModel.heroItems(),
            selectionResetRevision: heroSelectionResetRevision,
            // The Siri Remote's Back press while the page is scrolled down:
            // focus goes back to the hero and the page follows it up.
            focusRequestRevision: scrollToTopRevision,
            claimsInitialFocus: true,
            onScrolledOffTopChange: { isScrolledOffTop = $0 },
            play: play,
            header: {
                homeHeader()
                    .padding(.horizontal, DuskPosterMetrics.carouselHorizontalPadding)
                    .padding(.top, 24 + DuskPosterMetrics.pageSectionSpacing)
                    .padding(.bottom, 56)
            },
            heroAccessory: { EmptyView() },
            cardMenu: { item in
                HomeItemContextMenu(
                    item: item,
                    detailsLabel: heroDetailsLabel(for: item),
                    onMarkWatched: {
                        Task { await viewModel.setWatched(true, for: item) }
                    },
                    onMarkUnwatched: {
                        Task { await viewModel.setWatched(false, for: item) }
                    },
                    onSelectRoute: { route in
                        path.append(route)
                    },
                    onRemoveFromContinueWatching: {
                        Task { await viewModel.removeFromContinueWatching(item) }
                    }
                )
            },
            shelves: {
                // A plain `VStack`, not a `LazyVStack`: the first shelf starts
                // right at the fold, and a lazy stack can have nothing
                // materialised there when the user presses down, which leaves
                // the focus engine without a target.
                VStack(alignment: .leading, spacing: DuskPosterMetrics.pageSectionSpacing) {
                    shelves()
                }
                .padding(.bottom, DuskPosterMetrics.pageBottomPadding)
            }
        )
        .task(id: showsLiveTV) {
            guard showsLiveTV else { return }
            await liveTVViewModel.loadNowPlaying(force: true)
        }
    }

    @ViewBuilder
    private func shelves() -> some View {
        ServerOutageNote(offlineServerNames: offlineServerNames)
            .padding(.horizontal, DuskPosterMetrics.carouselHorizontalPadding)

        if showsLiveTV {
            LiveTVHomeShelf(viewModel: liveTVViewModel, play: playLiveTV)
        }

        ForEach(viewModel.hubs) { hub in
            let items = viewModel.inlineItems(
                in: hub,
                maxRecentlyAddedItems: recentlyAddedInlineItemLimit
            )

            if !items.isEmpty {
                let isVideoHub = viewModel.isVideoHub(hub)

                PlexItemPosterCarouselSection(
                    title: hub.title,
                    items: items,
                    posterWidth: isVideoHub
                        ? DuskPosterMetrics.videoCarouselWidth
                        : DuskPosterMetrics.carouselPosterWidth,
                    imageAspectRatio: isVideoHub ? 16.0 / 9.0 : 2.0 / 3.0,
                    showAllRoute: viewModel.shouldShowAll(
                        for: hub,
                        maxRecentlyAddedItems: recentlyAddedInlineItemLimit
                    ) ? AppNavigationRoute.hub(hub) : nil,
                    subtitle: { isVideoHub ? $0.standardPosterSubtitle : $0.hubPosterSubtitle },
                    posterURL: { item, width, height in
                        viewModel.posterURL(for: item, width: width, height: height)
                    }
                ) { item in
                    PlexItemContextMenuContent(
                        item: item,
                        onMarkWatched: {
                            Task { await viewModel.setWatched(true, for: item) }
                        },
                        onMarkUnwatched: {
                            Task { await viewModel.setWatched(false, for: item) }
                        }
                    )
                }
            }
        }

        ForEach(viewModel.personalizedShelves) { shelf in
            if !shelf.items.isEmpty {
                PlexItemPosterCarouselSection(
                    title: shelf.title,
                    items: shelf.items,
                    posterWidth: DuskPosterMetrics.carouselPosterWidth,
                    showAllRoute: viewModel.showAllRoute(for: shelf),
                    subtitle: { item in
                        viewModel.subtitle(for: item)
                    },
                    posterURL: { item, width, height in
                        viewModel.posterURL(for: item, width: width, height: height)
                    }
                ) { item in
                    PlexItemContextMenuContent(
                        item: item,
                        onMarkWatched: {
                            Task { await viewModel.setWatched(true, for: item) }
                        },
                        onMarkUnwatched: {
                            Task { await viewModel.setWatched(false, for: item) }
                        }
                    )
                }
            }
        }
    }

    /// The server name used to sit under this title. With every server merged
    /// into one Home there is no single server to name, and naming the primary
    /// would be a lie about where the rows came from.
    private func homeHeader() -> some View {
        Text("Home")
            .font(DuskFont.TV.pageTitleRounded)
            .foregroundStyle(Color.primary)
    }

    private func heroDetailsLabel(for item: PlexItem) -> String {
        switch item.type {
        case .episode, .season, .show:
            // Episodes and seasons open the show page too (on their own season).
            return "Show Details"
        case .movie:
            return "Movie Details"
        default:
            return "View Details"
        }
    }
}
#endif
