import Foundation
import Testing
@testable import Dusk

/// The library grid's Unwatched filter: the Plex parameter per library type,
/// how it combines with collection and genre filters, and the per-library
/// memory of the choice.
@Suite("Library unwatched filter")
struct LibraryUnwatchedFilterTests {
    @Test("Shows filter on their episodes, movies and videos on the item")
    func parameterPerLibraryType() {
        #expect(LibraryUnwatchedFilter.parameterName(for: .show) == "unwatchedLeaves")
        #expect(LibraryUnwatchedFilter.parameterName(for: .movie) == "unwatched")
        #expect(LibraryUnwatchedFilter.parameterName(for: .video) == "unwatched")
        #expect(LibraryUnwatchedFilter.parameterName(for: nil) == "unwatched")
    }

    @Test("Off adds nothing to the query")
    func offAddsNoFilter() {
        let filters = LibraryUnwatchedFilter.serverFilters(
            libraryType: .movie,
            collectionKey: nil,
            unwatchedOnly: false,
            genreValue: nil
        )
        #expect(filters.isEmpty)
    }

    @Test("Combines with collection scoping and the genre")
    func combinesWithOtherFilters() {
        let filters = LibraryUnwatchedFilter.serverFilters(
            libraryType: .show,
            collectionKey: "42",
            unwatchedOnly: true,
            genreValue: "7"
        )
        #expect(filters == ["collection": "42", "unwatchedLeaves": "1", "genre": "7"])
    }

    @Test("Remembered per library and cleared when turned off")
    func persistsPerLibrary() throws {
        let suiteName = "LibraryUnwatchedFilterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = LibraryUnwatchedFilterStore(defaults: defaults)
        #expect(!store.isEnabled(forLibraryID: "server-a|1"))

        store.setEnabled(true, forLibraryID: "server-a|1")
        #expect(store.isEnabled(forLibraryID: "server-a|1"))
        // The same section key on another server is a different library.
        #expect(!store.isEnabled(forLibraryID: "server-b|1"))
        #expect(LibraryUnwatchedFilterStore(defaults: defaults).isEnabled(forLibraryID: "server-a|1"))

        store.setEnabled(false, forLibraryID: "server-a|1")
        #expect(!store.isEnabled(forLibraryID: "server-a|1"))
        #expect(defaults.object(forKey: LibraryUnwatchedFilterStore.key(forLibraryID: "server-a|1")) == nil)
    }
}
