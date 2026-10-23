import SwiftUI

struct LibraryItemsView: View {
    @State private var viewModel: LibraryItemsViewModel
    private let horizontalPadding: CGFloat = DuskPosterMetrics.gridHorizontalPadding
    private let gridSpacing: CGFloat = DuskPosterMetrics.gridSpacing
    private let gridRowSpacing: CGFloat = DuskPosterMetrics.gridRowSpacing
    private let minimumColumnCount = 2
    private let controlCornerRadius: CGFloat = 18

    @FocusState private var focusedItemID: PlexItemID?
    /// The latest A–Z jump; a newer one (scrubbing) supersedes it.
    @State private var jumpTask: Task<Void, Never>?
    @State private var isJumping = false
    @State private var scrollPosition = ScrollPosition()
    @State private var prependAnchor = PrependAnchor()

    /// Plain storage for the scroll offset at the moment rows are prepended;
    /// not observed, so scrolling does not re-render the screen.
    private final class PrependAnchor {
        var offset: CGFloat = 0
        var isPending = false
        /// A scroll set mid-fling loses to the momentum, so rows are only
        /// inserted once the scroll view is not decelerating.
        var isDecelerating = false
        var settlesAt = Date.distantPast
    }
    #if os(tvOS)
    /// Shows the A–Z strip while focus races through the grid.
    @State private var revealsLetterIndex = false
    @State private var recentFocusMoves: [Date] = []
    /// The grid card that had focus last; still set while the strip has it.
    @State private var lastFocusedItemID: PlexItemID?
    @State private var letterIndexHideTask: Task<Void, Never>?
    #endif

    init(
        library: PlexLibrary,
        plexService: PlexService,
        collection: PlexLibraryCollection? = nil,
        initialGenre: LibraryGenreOption? = nil
    ) {
        _viewModel = State(initialValue: LibraryItemsViewModel(
            library: library,
            plexService: plexService,
            collection: collection,
            initialGenre: initialGenre
        ))
    }

    /// Video libraries browse in 16:9 clip cards; movie/show grids keep the
    /// standard 2:3 posters.
    private var preferredPosterWidth: CGFloat {
        viewModel.isVideoLibrary ? DuskPosterMetrics.videoGridPreferredWidth : DuskPosterMetrics.gridPreferredWidth
    }

    private var gridImageAspectRatio: CGFloat {
        viewModel.isVideoLibrary ? 16.0 / 9.0 : 2.0 / 3.0
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.items.isEmpty {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.items.isEmpty, !viewModel.showsBrowseControls {
                FeatureErrorView(message: error) {
                    Task { await viewModel.loadItems() }
                }
            } else {
                libraryContent
            }
        }
        .duskNavigationTitle(viewModel.navigationTitle)
        .duskNavigationBarTitleDisplayModeLarge()
        .task {
            await viewModel.loadItems()
        }
    }

    private var libraryContent: some View {
        GeometryReader { geometry in
            let layout = AdaptivePosterGridLayout.make(
                containerWidth: geometry.size.width - letterIndexGutter,
                horizontalPadding: horizontalPadding,
                gridSpacing: gridSpacing,
                preferredPosterWidth: preferredPosterWidth,
                minimumColumnCount: minimumColumnCount
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if viewModel.showsBrowseControls {
                        browseControls
                    }

                    if viewModel.hasEarlierItems, !viewModel.items.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }

                    if let error = viewModel.error, viewModel.items.isEmpty {
                        FeatureErrorView(message: error) {
                            Task { await viewModel.reloadItems() }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.top, 40)
                    } else if viewModel.items.isEmpty {
                        emptyView
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 24)
                            .padding(.top, 40)
                    } else {
                        posterGrid(layout)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.trailing, letterIndexGutter)
                        .padding(.top, 32)
                        .padding(.bottom, 32)
                    }

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollPosition($scrollPosition)
            // After a jump, the rows before the window load while they are
            // still 1.5 screens away, not once the top is hit mid-fling.
            .onScrollGeometryChange(for: CGPoint.self) { geometry in
                CGPoint(x: geometry.containerSize.height, y: geometry.contentOffset.y)
            } action: { _, geometry in
                prependAnchor.offset = geometry.y
                if geometry.y < geometry.x * 1.5 { loadEarlierItems() }
            }
            .onScrollPhaseChange { _, phase in
                prependAnchor.isDecelerating = phase == .decelerating || phase == .animating
            }
            // A page prepended above the window: move down by exactly what
            // was inserted, so the titles on screen stay put.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
                guard prependAnchor.isPending, new > old else { return }
                prependAnchor.isPending = false
                prependAnchor.offset += new - old
                // The next offset report or two can still be the old one.
                prependAnchor.settlesAt = .now + 0.4
                scrollPosition.scrollTo(y: prependAnchor.offset)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .overlay(alignment: .trailing) {
                if let index = viewModel.letterIndex, !viewModel.items.isEmpty {
                    letterIndexBar(index)
                }
            }
        }
    }

    // MARK: - A–Z Jump

    /// iOS keeps the last column's titles clear of the index; the tvOS strip
    /// sits in the screen's trailing margin instead.
    private var letterIndexGutter: CGFloat {
        #if os(tvOS)
        0
        #else
        viewModel.letterIndex == nil ? 0 : 12
        #endif
    }

    @ViewBuilder
    private func letterIndexBar(_ index: LibraryLetterIndex) -> some View {
        #if os(tvOS)
        LibraryLetterIndexBar(
            index: index,
            currentEntry: lastFocusedItem.flatMap(viewModel.letterEntry(for:)),
            isRevealed: revealsLetterIndex,
            onSelect: { jump(to: $0) }
        )
        // Into the trailing margin, clear of the last column's posters.
        .padding(.trailing, -56)
        .onChange(of: focusedItemID) { _, id in
            guard let id else { return }
            lastFocusedItemID = id
            noteFocusMove()
        }
        #else
        LibraryLetterIndexBar(index: index) { jump(to: $0) }
            .padding(.trailing, 2)
        #endif
    }

    private func jump(to entry: LibraryLetterIndex.Entry) {
        jumpTask?.cancel()
        isJumping = true
        jumpTask = Task {
            defer { if !Task.isCancelled { isJumping = false } }
            guard let target = await viewModel.jump(to: entry), !Task.isCancelled else { return }
            // One layout pass for a freshly loaded window before scrolling.
            await Task.yield()
            scrollPosition.scrollTo(id: target.id, anchor: .top)
            // A lazy grid scrolls to a row it has not laid out by estimate,
            // and rows differ in height (two-line titles); once the target is
            // on screen a second pass lands it exactly.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            scrollPosition.scrollTo(id: target.id, anchor: .top)
            #if os(tvOS)
            focusedItemID = target.id
            #endif
        }
    }

    private func loadEarlierItems() {
        guard viewModel.hasEarlierItems, !isJumping, !viewModel.isLoadingEarlier,
              !prependAnchor.isPending, Date.now >= prependAnchor.settlesAt else { return }
        Task {
            await viewModel.loadEarlierItems {
                while prependAnchor.isDecelerating, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            } willPrepend: {
                prependAnchor.isPending = true
            }
        }
    }

    #if os(tvOS)
    private var lastFocusedItem: PlexItem? {
        guard let lastFocusedItemID else { return nil }
        return viewModel.items.first { $0.id == lastFocusedItemID }
    }

    /// Five focus moves within a second is a held-down remote or a fast
    /// swipe: reveal the strip, and hide it again once the grid settles.
    private func noteFocusMove() {
        let now = Date()
        recentFocusMoves = recentFocusMoves.filter { now.timeIntervalSince($0) < 1 } + [now]
        guard recentFocusMoves.count >= 5 else { return }
        revealsLetterIndex = true
        letterIndexHideTask?.cancel()
        letterIndexHideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            revealsLetterIndex = false
        }
    }
    #endif

    private var browseControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                #if os(iOS)
                // First on iPhone, where the row scrolls: it switches what the
                // screen lists rather than filtering it. tvOS keeps links after
                // the filters, where every chip is on screen anyway.
                if viewModel.hasCollections {
                    collectionsLink
                }
                #endif

                if viewModel.availableGenres.count > 1 {
                    genreMenu
                }

                unwatchedToggle

                sortMenu

                #if os(tvOS)
                if viewModel.hasCollections {
                    collectionsLink
                }
                #endif

                if viewModel.isLoading && !viewModel.items.isEmpty {
                    ProgressView()
                        .padding(.leading, 6)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        #if os(tvOS)
        // So Up from any poster in the first row can reach a chip, not only
        // from the poster that happens to sit under one.
        .focusSection()
        #endif
    }

    private var collectionsLink: some View {
        browseChipLink(
            .libraryCollections(viewModel.library),
            title: "Collections",
            systemImage: "square.stack"
        )
    }

    private func browseChipLink(
        _ route: AppNavigationRoute,
        title: String,
        systemImage: String
    ) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(DuskFont.glyphMedium(ios: .headline))
                    .foregroundStyle(Color.duskTextSecondary)

                Text(title)
                    .font(DuskFont.buttonLabel(ios: .subheadline.weight(.medium)))
                    .foregroundStyle(Color.duskTextPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                    .fill(Color.duskSurface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                    .stroke(Color.duskTextSecondary.opacity(0.18), lineWidth: 1)
            }
            .duskTVOSFocusEffectShape(RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous))
        }
        .duskSuppressTVOSButtonChrome()
    }

    private var genreMenu: some View {
        Menu {
            Section("Genre") {
                ForEach(viewModel.availableGenres) { genre in
                    Button {
                        Task { await viewModel.selectGenre(genre) }
                    } label: {
                        if genre == viewModel.selectedGenre {
                            Label(genre.title, systemImage: "checkmark")
                        } else {
                            Text(genre.title)
                        }
                    }
                }
            }
        } label: {
            browseControlLabel(
                value: viewModel.selectedGenre.title,
                systemImage: "line.3.horizontal.decrease.circle",
                isActive: viewModel.selectedGenre != .all
            )
        }
        .duskSuppressTVOSButtonChrome()
    }

    private var sortMenu: some View {
        Menu {
            Section("Sort") {
                ForEach(viewModel.availableSortOptions) { sort in
                    Button {
                        Task { await viewModel.selectSort(sort) }
                    } label: {
                        if sort == viewModel.selectedSort {
                            Label(sort.title, systemImage: "checkmark")
                        } else {
                            Text(sort.title)
                        }
                    }
                }
            }
        } label: {
            browseControlLabel(
                value: viewModel.selectedSort.title,
                systemImage: "arrow.up.arrow.down.circle",
                isActive: viewModel.selectedSort != viewModel.defaultSortOption
            )
        }
        .duskSuppressTVOSButtonChrome()
    }

    /// A filter chip rather than a menu: one tap (one click on tvOS) flips it.
    /// On, it inverts to a `TextPrimary` fill with a filled checkmark, the
    /// STYLE.md selected treatment, so the active filter reads at a glance.
    private var unwatchedToggle: some View {
        let isOn = viewModel.showsUnwatchedOnly

        return Button {
            Task { await viewModel.setShowsUnwatchedOnly(!isOn) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(DuskFont.glyphMedium(ios: .headline))
                    .foregroundStyle(isOn ? Color.duskBackground : Color.duskTextSecondary)

                Text("Unwatched")
                    .font(DuskFont.buttonLabel(ios: .subheadline.weight(.medium)))
                    .foregroundStyle(isOn ? Color.duskBackground : Color.duskTextPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                    .fill(isOn ? Color.duskTextPrimary : Color.duskSurface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                    .stroke(isOn ? Color.clear : Color.duskTextSecondary.opacity(0.18), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Unwatched only")
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .duskTVOSFocusEffectShape(RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous))
        }
        .duskSuppressTVOSButtonChrome()
        .animation(.snappy(duration: 0.2), value: isOn)
    }

    private func browseControlLabel(
        value: String,
        systemImage: String,
        isActive: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(DuskFont.glyphMedium(ios: .headline))
                .foregroundStyle(isActive ? Color.duskTextPrimary : Color.duskTextSecondary)

            Text(value)
                .font(DuskFont.buttonLabel(ios: .subheadline.weight(.medium)))
                .foregroundStyle(Color.duskTextPrimary)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(DuskFont.glyphSmall(ios: .caption.weight(.semibold)))
                .foregroundStyle(Color.duskTextSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                .fill(Color.duskSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                .stroke(
                    isActive ? Color.duskTextPrimary.opacity(0.35) : Color.duskTextSecondary.opacity(0.18),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(systemImage == "line.3.horizontal.decrease.circle" ? "Genre" : "Sort")
        .accessibilityValue(value)
        .duskTVOSFocusEffectShape(RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous))
    }

    private func posterGrid(_ layout: AdaptivePosterGridLayout) -> some View {
        viewModel.gridColumnCount = layout.columns.count
        return PlexItemPosterGrid(
            items: viewModel.items,
            layout: layout,
            rowSpacing: gridRowSpacing,
            imageAspectRatio: gridImageAspectRatio,
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            },
            subtitle: { viewModel.subtitle(for: $0) },
            progress: { viewModel.progress(for: $0) },
            onItemAppear: { item in
                Task { await viewModel.loadMoreIfNeeded(currentItem: item) }
            },
            // A Videos library or folder plays through, in the grid's order.
            playThroughTitle: viewModel.library.libraryType == .video ? viewModel.navigationTitle : nil,
            focusedItemID: $focusedItemID,
            isScrollTargetLayout: true
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

    private var emptyView: some View {
        FeatureEmptyStateView(
            systemImage: viewModel.emptyStateSystemImage,
            title: viewModel.emptyStateTitle,
            message: viewModel.emptyStateMessage
        )
    }
}
