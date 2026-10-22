import Foundation
import Testing
@testable import Dusk

/// What a poster card in a hub row or grid shows from the item's own Plex
/// watch state: the progress bar from `viewOffset`, the checkmark from
/// `viewCount` (or every episode watched for shows and seasons).
@Suite("Poster watch state")
struct PosterWatchStateTests {
    private func item(_ fields: [String: Any]) throws -> PlexItem {
        var json: [String: Any] = ["ratingKey": "1", "key": "/library/metadata/1", "title": "Item"]
        json.merge(fields) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "server"
        return try decoder.decode(PlexItem.self, from: data)
    }

    @Test("A partly watched clip gets a bar and no checkmark")
    func partlyWatchedClip() throws {
        let clip = try item(["type": "movie", "subtype": "clip", "duration": 600_000, "viewOffset": 150_000])
        #expect(clip.posterProgress == 0.25)
        #expect(!clip.posterIsWatched)
    }

    @Test("Watched movies, episodes and clips get the checkmark")
    func watchedLeaves() throws {
        for type in ["movie", "episode", "clip"] {
            let watched = try item(["type": type, "duration": 600_000, "viewCount": 1])
            #expect(watched.posterIsWatched, "\(type)")
            #expect(watched.posterProgress == nil, "\(type)")
        }
        #expect(!(try item(["type": "movie", "duration": 600_000])).posterIsWatched)
    }

    @Test("Shows and seasons only when every episode is watched")
    func showsAndSeasons() throws {
        #expect(try item(["type": "show", "leafCount": 6, "viewedLeafCount": 6]).posterIsWatched)
        #expect(!(try item(["type": "season", "leafCount": 6, "viewedLeafCount": 2])).posterIsWatched)
        #expect(!(try item(["type": "show", "leafCount": 0, "viewedLeafCount": 0])).posterIsWatched)
        #expect(!(try item(["type": "collection", "viewCount": 3])).posterIsWatched)
    }
}
