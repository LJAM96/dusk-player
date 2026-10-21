import Foundation

/// Drops the content of libraries the account has hidden.
///
/// Hidden is the plex.tv `pinnedSources[].isHidden` flag (Settings › Libraries ›
/// Hidden Libraries, or the same switch in Plex Web), read through
/// `LibraryOrderStore.hiddenLibraryFilter`. A hidden library is gone from Dusk
/// completely, so everything that can surface items from more than one library
/// — Home hubs and Continue Watching, search, hub paging, a person's titles,
/// recommendations, Siri — runs its results through this.
///
/// Matching is on `"<serverID>|<librarySectionID>"`, the `PlexLibrary.id`
/// shape: section keys are per-server counters. An item or hub that does not
/// say which section it belongs to is kept, because there is nothing to match
/// it against.
struct HiddenLibraryFilter: Sendable {
    let hiddenLibraryIDs: Set<String>

    static let none = HiddenLibraryFilter(hiddenLibraryIDs: [])

    func hides(serverID: String?, librarySectionID: String?) -> Bool {
        guard !hiddenLibraryIDs.isEmpty,
              let serverID = serverID?.nilIfEmpty,
              let librarySectionID = librarySectionID?.nilIfEmpty else { return false }
        return hiddenLibraryIDs.contains("\(serverID)|\(librarySectionID)")
    }

    func hides(_ library: PlexLibrary) -> Bool {
        hiddenLibraryIDs.contains(library.id)
    }

    func hides(_ item: PlexItem) -> Bool {
        hides(serverID: item.serverID, librarySectionID: item.librarySectionID)
    }

    func filtering(_ items: [PlexItem]) -> [PlexItem] {
        guard !hiddenLibraryIDs.isEmpty else { return items }
        return items.filter { !hides($0) }
    }

    /// Drops the rows of hidden libraries, and the hidden libraries' items from
    /// global rows (Recently Added, Continue Watching, search groups). A global
    /// row left with nothing in it is dropped too. Expects one server's
    /// unmerged hubs: a merged row has no single `serverID`.
    func filtering(_ hubs: [PlexHub]) -> [PlexHub] {
        guard !hiddenLibraryIDs.isEmpty else { return hubs }
        return hubs.compactMap { hub in
            guard !hides(serverID: hub.serverID, librarySectionID: hub.resolvedLibrarySectionID) else {
                return nil
            }
            let items = filtering(hub.items)
            guard items.count != hub.items.count else { return hub }
            return items.isEmpty ? nil : hub.replacingItems(items)
        }
    }
}
