import Foundation

/// A movie or TV library's Plex collections, manual and smart alike, paged
/// in the server's order (title).
@MainActor
@Observable
final class LibraryCollectionsViewModel {
    private let plexService: PlexService
    let library: PlexLibrary
    let pager: PlexItemPager

    init(library: PlexLibrary, plexService: PlexService) {
        self.library = library
        self.plexService = plexService
        let sectionID = library.key
        let serverID = library.serverID
        self.pager = PlexItemPager { [plexService] start, size in
            try await plexService.getCollections(
                sectionId: sectionID,
                start: start,
                size: size,
                serverID: serverID
            )
        }
    }

    var items: [PlexItem] { pager.items }

    var navigationTitle: String { "Collections" }

    func load() async {
        await pager.loadIfNeeded()
    }

    func reload() async {
        await pager.reload()
    }

    func loadMoreIfNeeded(currentItem: PlexItem) async {
        await pager.loadMoreIfNeeded(currentItem: currentItem)
    }

    func posterURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        item.posterImageURL(plexService: plexService, width: width, height: height)
    }

    func subtitle(for item: PlexItem) -> String? {
        item.collectionCountLabel
    }
}
