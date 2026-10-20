import SwiftUI
#if os(tvOS)
import UIKit

/// tvOS: a page that opens on a full-screen featured hero, like the Apple TV
/// app: the focused item's artwork fills the display, its title (clear logo,
/// else text), metadata and summary sit on the left, and a row of small
/// landscape cards holds the featured items. Moving focus across the cards
/// cross-fades the artwork and text to the focused one; selecting a card
/// plays it. Down from the row goes to the page's shelves.
///
/// Used by Home (Continue Watching) and the Movies / TV Shows library pages.
///
/// The hero is one ordinary row of cards, so every move in and out of it is
/// the focus engine's own geometric move between rows, the same as between
/// any two shelves. The only thing the page adds is `TVFeaturedHeroFoldSnapping`,
/// which keeps the page at one of two stops: the full hero, or the first shelf
/// at the top of the display.
struct TVFeaturedHeroPage<Header: View, HeroAccessory: View, CardMenu: View, Shelves: View>: View {
    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var focusScope
    @FocusState private var focusedKey: String?

    /// The header of the card row, e.g. "Continue Watching".
    let rowTitle: String
    /// The featured items. Empty: no hero, the page starts with `header`.
    let items: [PlexItem]
    /// Bumped to bring the hero back to its first item (Home reselected, the
    /// app reactivated, playback over).
    var selectionResetRevision = 0
    /// Bumped to move focus to the hero (the Siri Remote's Back press while
    /// the page is scrolled down). The focus engine's reveal scroll carries
    /// the page up.
    var focusRequestRevision = 0
    /// Whether the hero takes focus when it first appears. Home does; a
    /// library page leaves focus where the tab bar hands it.
    var claimsInitialFocus = false
    /// Whether the page is scrolled away from the hero. Only reported while
    /// there is a hero.
    var onScrolledOffTopChange: (Bool) -> Void = { _ in }
    let play: (PlexItem) -> Void
    /// The top of the page when there is no hero.
    @ViewBuilder let header: () -> Header
    /// Controls at the top of the hero, under the tab bar (the library
    /// pages' Browse buttons).
    @ViewBuilder let heroAccessory: () -> HeroAccessory
    @ViewBuilder let cardMenu: (PlexItem) -> CardMenu
    @ViewBuilder let shelves: () -> Shelves

    /// The item the hero shows: the focused card's, or the last one focused
    /// while focus is elsewhere.
    @State private var selectedKey: String?
    @State private var isHeroShowing = true
    @State private var hasClaimedInitialFocus = false
    /// Only `settle` scrolls through this, once the page is still.
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var settle = TVFeaturedHeroSettle()

    private var itemKeys: [String] {
        items.map(\.id.storageKey)
    }

    var body: some View {
        GeometryReader { geometry in
            let hasHero = !items.isEmpty
            let globalFrame = geometry.frame(in: .global)
            let screenSize = Self.screenSize
            let screenWidth = max(screenSize?.width ?? 0, geometry.size.width)
            let leadingInset = max(globalFrame.minX, 0)
            let trailingInset = max(screenWidth - globalFrame.maxX, 0)
            // The hero owns the whole display. `geometry.size` is the
            // safe-area-inset content box, so add the insets back and floor
            // the result at the real screen height.
            let heroHeight = max(
                screenSize?.height ?? 0,
                geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if hasHero {
                        TVFeaturedHero(
                            items: items,
                            rowTitle: rowTitle,
                            focusedKey: $focusedKey,
                            selectedKey: selectedKey ?? itemKeys.first,
                            focusScope: focusScope,
                            size: CGSize(width: screenWidth, height: heroHeight),
                            contentLeadingInset: leadingInset,
                            contentTrailingInset: trailingInset,
                            topInset: geometry.safeAreaInsets.top,
                            selectionResetRevision: selectionResetRevision,
                            play: play,
                            accessory: heroAccessory,
                            cardMenu: cardMenu
                        )
                        .frame(width: screenWidth, height: heroHeight)
                        .offset(x: -leadingInset)

                        // No `.focusSection()` here or around the hero: a move
                        // into a section is steered towards its middle, which
                        // for this tall stack sent a down-press from the card
                        // row to the fourth shelf (measured in the simulator).
                        shelves()
                            // Pressing down scrolls the shelves' top to the
                            // top of the display, under the floating tab bar.
                            .padding(.top, max(geometry.safeAreaInsets.top, 60) + 24)
                    } else {
                        header()
                        shelves()
                    }
                }
                .frame(width: geometry.size.width, alignment: .leading)
            }
            // With a hero, the content starts at the very top of the display
            // with no top inset: the artwork sits at screen y = 0, and content
            // y = scroll offset, which the fold snapping relies on.
            .ignoresSafeArea(edges: hasHero ? .top : [])
            .scrollPosition($scrollPosition)
            .scrollTargetBehavior(
                TVFeaturedHeroFoldSnapping(
                    foldY: hasHero ? heroHeight : nil,
                    startsAboveFold: focusedKey != nil || isHeroShowing
                )
            )
            .onScrollGeometryChange(for: Bool.self) { scrollGeometry in
                scrollGeometry.contentOffset.y + scrollGeometry.contentInsets.top < heroHeight * 0.5
            } action: { _, isShowing in
                isHeroShowing = isShowing
            }
            .onScrollGeometryChange(for: Bool.self) { scrollGeometry in
                hasHero && TVFeaturedHeroScrollMetrics(scrollGeometry).offset > 1
            } action: { _, isOffTop in
                onScrolledOffTopChange(isOffTop)
            }
            .onScrollGeometryChange(for: TVFeaturedHeroScrollMetrics.self) { scrollGeometry in
                TVFeaturedHeroScrollMetrics(scrollGeometry)
            } action: { _, metrics in
                // Every frame while the page moves, so this stays out of
                // `@State`: the settle check only runs once it stops.
                settle.metrics = metrics
                scheduleSettle(heroHeight: hasHero ? heroHeight : nil)
            }
            .onChange(of: hasHero) { _, hasHero in
                if !hasHero { onScrolledOffTopChange(false) }
            }
            .onChange(of: focusedKey) { _, key in
                if let key { selectedKey = key }
                // A move the snapping kept in place scrolls nothing, so no
                // geometry change would schedule the settle check.
                scheduleSettle(heroHeight: hasHero ? heroHeight : nil)
            }
            .focusScope(focusScope)
            .contentMargins(.zero, for: .scrollContent)
            .contentMargins(.zero, for: .scrollIndicators)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .duskTVOSPageBackground()
            .defaultFocus($focusedKey, selectedKey ?? itemKeys.first)
            .task(id: itemKeys) {
                await itemsChanged()
            }
            .onChange(of: selectionResetRevision) { _, _ in
                let first = itemKeys.first
                selectedKey = first
                if focusedKey != nil {
                    focusedKey = first
                }
            }
            .onChange(of: focusRequestRevision) { _, _ in
                guard hasHero else { return }
                focusedKey = selectedKey ?? itemKeys.first
            }
            .onDisappear {
                settle.pending?.cancel()
            }
        }
    }

    @MainActor
    private func itemsChanged() async {
        let keys = itemKeys
        if let selectedKey, !keys.contains(selectedKey) {
            self.selectedKey = keys.first
        }

        guard claimsInitialFocus, !hasClaimedInitialFocus, let first = selectedKey ?? keys.first else { return }
        hasClaimedInitialFocus = true
        // Reset the scope after the hero enters the hierarchy, so the first
        // appearance lands on the card rather than wherever UIKit put focus.
        focusedKey = nil
        await Task.yield()
        resetFocus(in: focusScope)
        focusedKey = first
    }

    private func scheduleSettle(heroHeight: CGFloat?) {
        settle.pending?.cancel()
        guard let heroHeight else { return }

        settle.pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            settleFold(heroHeight: heroHeight)
        }
    }

    /// Safety net: once the page is still, make sure it rests at one of its
    /// two stops. With a card focused that is the full hero; otherwise never
    /// on a sliver of hero. Normally it does nothing.
    private func settleFold(heroHeight: CGFloat) {
        let metrics = settle.metrics
        // A short page may not scroll far enough to reach the fold at all.
        let fold = min(heroHeight, metrics.maxOffset)
        guard fold > 1, metrics.offset > 1 else { return }

        if focusedKey != nil {
            withAnimation(.easeInOut(duration: 0.35)) {
                scrollPosition.scrollTo(edge: .top)
            }
        } else if metrics.offset < fold - 1 {
            withAnimation(.easeInOut(duration: 0.35)) {
                if metrics.offset < fold * 0.5 {
                    scrollPosition.scrollTo(edge: .top)
                } else {
                    scrollPosition.scrollTo(y: fold)
                }
            }
        }
    }

    private static var screenSize: CGSize? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }?
            .screen.bounds.size
    }
}

/// The hero itself: artwork, text, accessory and the card row.
private struct TVFeaturedHero<Accessory: View, CardMenu: View>: View {
    @Environment(PlexService.self) private var plexService

    let items: [PlexItem]
    let rowTitle: String
    let focusedKey: FocusState<String?>.Binding
    let selectedKey: String?
    let focusScope: Namespace.ID
    let size: CGSize
    let contentLeadingInset: CGFloat
    let contentTrailingInset: CGFloat
    let topInset: CGFloat
    let selectionResetRevision: Int
    let play: (PlexItem) -> Void
    let accessory: () -> Accessory
    let cardMenu: (PlexItem) -> CardMenu

    /// The artwork on screen. Trails `selectedKey` until the new artwork is
    /// decoded, so a cross-fade never goes through an empty frame.
    @State private var shownBackdropKey: String?
    @State private var backdrops: [String: UIImage] = [:]
    @State private var failedBackdropKeys: Set<String> = []
    @State private var logos: [String: UIImage] = [:]
    @State private var failedLogoKeys: Set<String> = []
    @State private var rowPosition = ScrollPosition()

    private let cardWidth: CGFloat = 320
    private let cardAspectRatio: CGFloat = 16.0 / 9.0
    private let logoMaxSize = CGSize(width: 600, height: 140)
    private let textMaxWidth: CGFloat = 900
    private let crossFade = Animation.easeInOut(duration: 0.4)

    private var contentLeading: CGFloat {
        contentLeadingInset + DuskPosterMetrics.carouselHorizontalPadding
    }

    private var contentTrailing: CGFloat {
        contentTrailingInset + DuskPosterMetrics.carouselHorizontalPadding
    }

    private var selectedItem: PlexItem? {
        items.first { $0.id.storageKey == selectedKey } ?? items.first
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop

            VStack(alignment: .leading, spacing: 0) {
                accessory()
                    .padding(.top, topInset + DuskPosterMetrics.carouselHeaderSpacing)
                    .padding(.leading, contentLeading)
                    .padding(.trailing, contentTrailing)
                    // Full width, so up from any card reaches its controls,
                    // not only from the cards right below them.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()

                Spacer(minLength: 0)

                // A ZStack, so the outgoing and incoming text overlap while
                // they cross-fade instead of stacking for a moment.
                ZStack(alignment: .bottomLeading) {
                    if let selectedItem {
                        info(for: selectedItem)
                            .id(selectedItem.id.storageKey)
                            .transition(.opacity)
                    }
                }
                .animation(crossFade, value: selectedItem?.id.storageKey)
                .padding(.leading, contentLeading)
                .padding(.trailing, contentTrailing)
                .padding(.bottom, 44)
                // The backdrop's scrim is dark in both appearances.
                .environment(\.colorScheme, .dark)

                cardRow
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height)
        .duskTVOSStandardImageDynamicRange()
        .onChange(of: selectedKey, initial: true) { _, _ in
            updateShownBackdrop()
        }
        .onChange(of: selectionResetRevision) { _, _ in
            // A focused card hands focus to the first one and the engine
            // scrolls the row; only an unfocused row is rewound here.
            if focusedKey.wrappedValue == nil {
                rowPosition.scrollTo(edge: .leading)
            }
        }
        .task(id: prefetchSeed) {
            await prefetch()
        }
    }

    // MARK: Artwork

    private var backdrop: some View {
        ZStack {
            if let shownBackdropKey, let image = backdrops[shownBackdropKey] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .id(shownBackdropKey)
                    .transition(.opacity)
            }

            DuskHeroBackdropOverlay(style: .cinematic)
        }
        .frame(width: size.width, height: size.height)
        .animation(crossFade, value: shownBackdropKey)
        .duskHeroBackdropBottomFade(.fullBleed)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func updateShownBackdrop() {
        guard let item = selectedItem else {
            shownBackdropKey = nil
            return
        }
        let key = item.id.storageKey
        if backdrops[key] != nil {
            shownBackdropKey = key
        } else if backdropURLs(for: item).isEmpty || failedBackdropKeys.contains(key) {
            // Nothing to wait for: fade to the plain page.
            shownBackdropKey = nil
        }
        // Otherwise keep the current artwork until this one has decoded.
    }

    private func backdropURLs(for item: PlexItem) -> [URL] {
        item.tvFeaturedBackdropPaths.compactMap { path in
            plexService.imageURL(
                for: path,
                serverID: item.serverID,
                width: Int(size.width.rounded(.up)),
                height: Int(size.height.rounded(.up))
            )
        }
    }

    private func cardURLs(for item: PlexItem) -> [URL] {
        item.tvFeaturedCardPaths.compactMap { path in
            plexService.imageURL(
                for: path,
                serverID: item.serverID,
                width: Int(cardWidth.rounded(.up)),
                height: Int((cardWidth / cardAspectRatio).rounded(.up))
            )
        }
    }

    private func logoURL(for item: PlexItem) -> URL? {
        plexService.imageURL(
            for: item.clearLogo,
            serverID: item.serverID,
            width: Int(logoMaxSize.width),
            height: Int(logoMaxSize.height)
        )
    }

    private var prefetchSeed: String {
        items.map { "\($0.id.storageKey):\($0.clearLogo ?? "")" }.joined(separator: "|")
            + "::\(Int(size.width))x\(Int(size.height))"
    }

    /// Every featured item's artwork and logo, decoded off the main thread up
    /// front: left lazy, the full-screen backdrop decodes on the first frame
    /// of the cross-fade and stalls it right as focus lands.
    private func prefetch() async {
        let validKeys = Set(items.map(\.id.storageKey))
        backdrops = backdrops.filter { validKeys.contains($0.key) }
        failedBackdropKeys = failedBackdropKeys.filter { validKeys.contains($0) }
        logos = logos.filter { validKeys.contains($0.key) }
        failedLogoKeys = failedLogoKeys.filter { validKeys.contains($0) }

        // The selected item first, so the hero paints as soon as possible.
        let ordered = items.filter { $0.id.storageKey == selectedKey }
            + items.filter { $0.id.storageKey != selectedKey }
        let backdropRequests = ordered.map { item in
            (item.id.storageKey, backdropURLs(for: item))
        }
        let logoRequests = ordered.compactMap { item in
            logoURL(for: item).map { (item.id.storageKey, $0) }
        }
        let plexService = plexService

        await withTaskGroup(of: (String, UIImage?, Bool).self) { group in
            for (key, urls) in backdropRequests
            where !urls.isEmpty && backdrops[key] == nil && !failedBackdropKeys.contains(key) {
                group.addTask {
                    // The first candidate that loads, e.g. the episode still
                    // when the show has no background art on the server.
                    for url in urls {
                        if let image = try? await DuskImageLoader.shared.image(for: url, using: plexService) {
                            return (key, await image.byPreparingForDisplay() ?? image, true)
                        }
                    }
                    return (key, nil, true)
                }
            }
            for (key, url) in logoRequests where logos[key] == nil {
                group.addTask {
                    let image = try? await DuskImageLoader.shared.image(for: url, using: plexService)
                    return (key, image, false)
                }
            }

            for await (key, image, isBackdrop) in group {
                guard !Task.isCancelled, validKeys.contains(key) else { continue }
                if isBackdrop {
                    if let image {
                        backdrops[key] = image
                    } else {
                        failedBackdropKeys.insert(key)
                    }
                    if key == selectedItem?.id.storageKey {
                        updateShownBackdrop()
                    }
                } else if let image {
                    logos[key] = image
                } else {
                    failedLogoKeys.insert(key)
                }
            }
        }
    }

    // MARK: Text

    private func info(for item: PlexItem) -> some View {
        let metadata = item.featuredMetadata

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: item.type == .movie ? 14 : 10) {
                title(for: item)

                if let episodeTitle = item.featuredEpisodeTitle {
                    Text(episodeTitle)
                        .font(DuskFont.TV.heroSubtitle)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                }

                if !metadata.isEmpty {
                    Text(metadata.joined(separator: " · "))
                        .font(DuskFont.TV.metadata)
                        .foregroundStyle(Color.primary.opacity(0.78))
                        .lineLimit(1)
                }
            }

            if let summary = item.featuredSummary {
                Text(summary)
                    .font(DuskFont.TV.body)
                    .foregroundStyle(Color.primary.opacity(0.76))
                    .lineLimit(3)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: textMaxWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func title(for item: PlexItem) -> some View {
        let key = item.id.storageKey
        if let logo = logos[key] {
            Image(uiImage: logo)
                .resizable()
                .scaledToFit()
                .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
                .frame(width: logoMaxSize.width, height: logoMaxSize.height, alignment: .bottomLeading)
                .accessibilityLabel(item.continueWatchingDisplayTitle)
        } else if item.clearLogo != nil, !failedLogoKeys.contains(key) {
            // Still loading: hold the logo's space so the text below does not
            // jump when it arrives.
            Color.clear
                .frame(width: logoMaxSize.width, height: logoMaxSize.height)
        } else {
            Text(item.continueWatchingDisplayTitle)
                .font(DuskFont.TV.heroTitleRounded)
                .foregroundStyle(Color.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
        }
    }

    // MARK: Cards

    private var cardRow: some View {
        VStack(alignment: .leading, spacing: DuskPosterMetrics.carouselSectionSpacing) {
            Text(rowTitle)
                .font(DuskFont.TV.sectionHeader)
                .foregroundStyle(Color.primary)
                .environment(\.colorScheme, .dark)
                .padding(.leading, contentLeading)
                .padding(.trailing, contentTrailing)

            ScrollView(.horizontal) {
                // Not lazy: the row holds a handful of items, and a card the
                // engine moves to must exist before it is on screen.
                HStack(spacing: DuskPosterMetrics.carouselItemSpacing) {
                    ForEach(items) { item in
                        card(for: item)
                    }
                }
                .padding(.leading, contentLeading)
                .padding(.trailing, contentTrailing)
                .padding(.bottom, DuskPosterMetrics.carouselBottomPadding)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .scrollPosition($rowPosition)
        }
        .padding(.bottom, 36)
    }

    private func card(for item: PlexItem) -> some View {
        let key = item.id.storageKey
        let shape = RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)
        let imageURLs = cardURLs(for: item)

        return Button {
            play(item)
        } label: {
            PosterArtwork(
                imageURL: imageURLs.first,
                fallbackImageURL: imageURLs.dropFirst().first,
                progress: item.posterProgress,
                width: cardWidth,
                imageAspectRatio: cardAspectRatio
            )
            .contentShape(.contextMenuPreview, shape)
        }
        .duskSuppressTVOSButtonChrome()
        .focused(focusedKey, equals: key)
        .prefersDefaultFocus(key == (selectedKey ?? items.first?.id.storageKey), in: focusScope)
        .duskTVOSFocusEffectShape(shape, scales: false)
        .contextMenu {
            cardMenu(item)
        }
        .duskTVOSFocusedScale(focusedKey.wrappedValue == key)
        .zIndex(focusedKey.wrappedValue == key ? 1 : 0)
        .accessibilityLabel(item.continueWatchingDisplayTitle)
        .accessibilityHint("Plays")
    }
}

private extension PlexItem {
    /// The hero's full-screen artwork, best first. Only 16:9 art: an
    /// episode shows its show's background rather than the episode still,
    /// and a poster or a 5:1 banner blown up to the whole screen looks worse
    /// than the plain page.
    var tvFeaturedBackdropPaths: [String] {
        let paths: [String?]
        switch type {
        case .episode:
            // An episode's own `art` is usually the show's, inherited.
            paths = [grandparentArt, art, thumb]
        default:
            paths = [art]
        }
        return Self.distinct(paths)
    }

    /// A card's artwork, best first: the show's 16:9 art for an episode or
    /// season, the item's own for a movie. A card always shows something,
    /// so a poster is the last resort.
    var tvFeaturedCardPaths: [String] {
        let paths: [String?]
        switch type {
        case .episode:
            paths = [grandparentArt, art, thumb, grandparentThumb]
        case .season:
            paths = [art, thumb, parentThumb]
        default:
            paths = [art, thumb]
        }
        return Self.distinct(paths)
    }

    private static func distinct(_ paths: [String?]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { $0 }.filter { seen.insert($0).inserted }
    }
}

/// Snaps the focus engine's own scroll between the page's two stops: the
/// full-screen hero, and the first shelf at the top of the display.
///
/// When focus moves to an item off screen, the focus engine scrolls the page
/// to reveal it, and SwiftUI runs that scroll's proposed end offset through
/// `updateTarget` first. This is the fold-snapping pattern from Apple's
/// "Creating a tvOS media catalog app in SwiftUI" sample.
///
/// Never pair it with a programmatic `scrollTo` on the same focus change: the
/// two scrolls stack, which used to throw a down-press from the hero rows
/// past the first shelf.
///
/// Offsets are plain content y values, because the scroll view has no top
/// content inset while there is a hero.
private struct TVFeaturedHeroFoldSnapping: ScrollTargetBehavior {
    /// Content y of the first shelf's top edge, i.e. the hero height. `nil`
    /// without a hero, which leaves every target alone.
    var foldY: CGFloat?
    /// Which side of the fold the scroll starts from, from the last render:
    /// the page as it was before the focus move that triggered the scroll.
    var startsAboveFold: Bool

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        // Only the vertical page scroll, never the rows' own.
        guard let foldY, foldY > 0, context.axes.contains(.vertical) else { return }
        let proposedY = target.rect.minY

        if startsAboveFold {
            // Everything in the hero is on screen at rest, so a real scroll
            // from up here is focus leaving for the shelves: land the first
            // shelf at the top. Nudges keep the hero where it is: a card the
            // row scrolls into view also asks the page to move down a bit
            // (~0.17 of the fold in the simulator), while a down-press to the
            // first shelf asks for ~0.79.
            target.rect.origin.y = proposedY < foldY * 0.5 ? 0 : foldY
        } else if proposedY < foldY {
            // Below the fold, stopping short of it would leave a sliver of
            // hero on screen. A target that shows a good part of the hero is
            // focus going back up to the card row at its bottom: show all of
            // it. Anything less is the engine nudging the first shelf, which
            // stays at the fold.
            target.rect.origin.y = proposedY < foldY * 0.85 ? 0 : foldY
        }
        // Targets past the fold are ordinary shelf-to-shelf scrolling.
    }
}

/// The parts of the scroll geometry the settle check needs.
private struct TVFeaturedHeroScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var maxOffset: CGFloat = 0

    init() {}

    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y + geometry.contentInsets.top
        maxOffset = max(
            geometry.contentSize.height
                + geometry.contentInsets.top
                + geometry.contentInsets.bottom
                - geometry.containerSize.height,
            0
        )
    }
}

/// The latest scroll metrics plus the pending settle check. A class on
/// purpose: scroll geometry updates it every frame, and `@State` would
/// re-render the page once per frame.
@MainActor
private final class TVFeaturedHeroSettle {
    var metrics = TVFeaturedHeroScrollMetrics()
    var pending: Task<Void, Never>?
}
#endif
