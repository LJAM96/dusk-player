import Foundation

/// A Plex collection (manual or smart): its own metadata plus its titles,
/// paged in the collection's sort order. Everything is read from the
/// collection's server.
@MainActor
@Observable
final class CollectionDetailViewModel {
    private let plexService: PlexService
    let id: PlexItemID
    let pager: PlexItemPager

    private(set) var collection: PlexItem?
    private(set) var isLoading = false
    private(set) var error: String?

    init(id: PlexItemID, plexService: PlexService) {
        self.id = id
        self.plexService = plexService
        let ratingKey = id.ratingKey
        let serverID = id.serverID
        self.pager = PlexItemPager { [plexService] start, size in
            try await plexService.getCollectionItems(
                ratingKey: ratingKey,
                start: start,
                size: size,
                serverID: serverID
            )
        }
    }

    var serverID: String? { id.serverID }
    var items: [PlexItem] { pager.items }

    var title: String { collection?.title ?? "" }

    var summary: String? { collection?.summary?.nilIfEmpty }

    /// Clip collections browse in 16:9 frame grabs like their library.
    var showsLandscapeItems: Bool {
        collection?.subtype == "clip" || (!items.isEmpty && items.allSatisfy(\.isClip))
    }

    /// `Smart Collection · 12 movies · 1977–2019`. The year span is only
    /// given once every title is loaded, so it never understates the range.
    var metadataLine: String? {
        guard let collection else { return nil }
        var parts = [collection.isSmartCollection ? "Smart Collection" : "Collection"]

        if let count = itemCountLabel {
            parts.append(count)
        }

        if !pager.hasMore {
            let years = items.compactMap(\.year)
            if let first = years.min(), let last = years.max() {
                parts.append(first == last ? String(first) : "\(first)–\(last)")
            }
        }

        return parts.joined(separator: " · ")
    }

    /// The collection's own count, else the server's page total. A smart
    /// collection's `childCount` can lag behind what its filter matches.
    private var itemCountLabel: String? {
        guard let collection else { return nil }
        let count = pager.totalSize ?? collection.childCount
        return count.map { PlexItem.collectionCountLabel($0, subtype: collection.subtype) }
    }

    /// Movies (and clips) can be played straight from the collection; a show
    /// collection is a shelf of shows, each with its own seasons, so it only
    /// browses.
    var isPlayable: Bool {
        !playableItems.isEmpty
    }

    private var playableItems: [PlexItem] {
        items.filter { $0.type == .movie || $0.isClip }
    }

    /// What Play starts: the title already in progress, else the first one
    /// not yet watched, else the first title.
    var nextUp: PlexItem? {
        let playable = playableItems
        return playable.first(where: \.isPartiallyWatched)
            ?? playable.first(where: { !$0.isWatched })
            ?? playable.first
    }

    var playButtonTitle: String {
        guard let nextUp else { return "Play" }
        if nextUp.isPartiallyWatched {
            return "Resume \(nextUp.title)"
        }
        return nextUp.id == playableItems.first?.id ? "Play" : "Play \(nextUp.title)"
    }

    /// Shuffle starts a random title, preferring the unwatched ones.
    func shuffledPick() -> PlexItem? {
        let playable = playableItems
        let unwatched = playable.filter { !$0.isWatched }
        return (unwatched.isEmpty ? playable : unwatched).randomElement()
    }

    func load() async {
        guard collection == nil, !isLoading else { return }
        isLoading = true
        error = nil

        async let items: Void = pager.reload()
        do {
            collection = try await plexService.getCollection(ratingKey: id.ratingKey, serverID: serverID)
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
        await items
        isLoading = false
    }

    /// Re-reads watch state after playback or a return to the foreground.
    func refresh() async {
        guard collection != nil else { return }
        await pager.reload()
    }

    func loadMoreIfNeeded(currentItem: PlexItem) async {
        await pager.loadMoreIfNeeded(currentItem: currentItem)
    }

    func setWatched(_ watched: Bool, for item: PlexItem) async {
        try? await plexService.setWatchedAcrossServers(watched, id: item.id)
        await pager.reload()
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        // A collection without its own background borrows its first title's.
        let path = collection?.art ?? items.first(where: { $0.art != nil })?.art ?? collection?.thumb
        return plexService.imageURL(for: path, serverID: serverID, width: width, height: height)
    }

    func posterURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        item.posterImageURL(plexService: plexService, width: width, height: height)
    }

    func subtitle(for item: PlexItem) -> String? {
        item.standardPosterSubtitle
    }
}
