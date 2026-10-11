#if os(tvOS)
import Foundation

/// What the tvOS Top Shelf shows, as handed from the app to the Top Shelf
/// extension through the shared App Group container.
///
/// This file is compiled into both the app and the `DuskTopShelf` extension.
/// The extension never talks to Plex: it has no token and no network access to
/// a server, only this snapshot and the artwork files the app cached next to
/// it. Titles, artwork file names and the deep links are all decided by the
/// app (see `TopShelfPublisher`).
struct TopShelfSnapshot: Codable, Sendable {
    struct Section: Codable, Sendable {
        var title: String
        var items: [Item]
    }

    struct Item: Codable, Sendable {
        /// Stable per item (`PlexItemID.storageKey`), so tvOS can keep focus
        /// on the same tile across updates.
        var id: String
        var title: String
        /// A file in `TopShelfStore.imagesDirectory`.
        var imageFileName: String
        /// 0...1, nil for an item that has not been started.
        var progress: Double?
        var playURL: URL
        var displayURL: URL
    }

    var sections: [Section]
}

/// Where the snapshot and its artwork live in the App Group container.
enum TopShelfStore {
    static let appGroupIdentifier = "group.com.dusk-player.app"

    /// nil when the binary is not entitled to the App Group (e.g. a build
    /// signed with a profile that predates the capability).
    static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appending(path: "Library/Application Support/TopShelf", directoryHint: .isDirectory)
    }

    static var snapshotURL: URL? {
        directory?.appending(path: "snapshot.json", directoryHint: .notDirectory)
    }

    static var imagesDirectory: URL? {
        directory?.appending(path: "Images", directoryHint: .isDirectory)
    }

    static func loadSnapshot() -> TopShelfSnapshot? {
        guard let snapshotURL, let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(TopShelfSnapshot.self, from: data)
    }
}
#endif
