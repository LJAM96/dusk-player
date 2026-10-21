#if os(tvOS)
import CoreImage
import CryptoKit
import Foundation
import OSLog
import TVServices

private let topShelfLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "TopShelf"
)

/// Mirrors Home's Continue Watching into the Top Shelf snapshot.
///
/// Home calls `publish` every time it publishes Continue Watching; this writes
/// `TopShelfSnapshot` plus the artwork into the App Group container and asks
/// tvOS to reload the Top Shelf. Artwork is fetched here, with the app's own
/// Plex session, and stored as plain files, so the extension never needs a
/// token. `clear` runs whenever the signed-in identity goes away (sign-out,
/// Plex Home switch): the shelf must never show the previous profile's items.
@MainActor
final class TopShelfPublisher {
    static let shared = TopShelfPublisher()

    private static let itemLimit = 10
    /// The 2x size of a 16:9 sectioned Top Shelf tile; Plex never upscales.
    private static let imageWidth = 1280
    private static let imageHeight = 720

    /// What was last written, so Home's repeated publishes of the same list
    /// (tab returns, refreshes) do not rewrite files or reload the shelf.
    private var publishedSignature: [String]?
    private var writeTask: Task<Void, Never>?

    func publish(continueWatching items: [PlexItem], plexService: PlexService) {
        let entries = items.prefix(Self.itemLimit).compactMap { Entry(item: $0, plexService: plexService) }
        let signature = entries.map(\.signature)
        // The snapshot lives in Caches, so it can be purged under a running app.
        let snapshotExists = TopShelfStore.snapshotURL.map {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        } ?? false
        guard signature != publishedSignature || !snapshotExists else { return }
        publishedSignature = signature

        writeTask?.cancel()
        writeTask = Task {
            await Self.write(entries, plexService: plexService)
        }
    }

    func clear() {
        writeTask?.cancel()
        writeTask = nil
        publishedSignature = nil

        guard let directory = TopShelfStore.directory,
              FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private static func write(_ entries: [Entry], plexService: PlexService) async {
        guard let imagesDirectory = TopShelfStore.imagesDirectory,
              let snapshotURL = TopShelfStore.snapshotURL else {
            topShelfLogger.error("App Group container unavailable; Top Shelf not updated")
            return
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        } catch {
            topShelfLogger.error("Could not create the Top Shelf directory: \(error.localizedDescription, privacy: .public)")
            return
        }

        // A tile without artwork is an empty rectangle on the Home Screen, so
        // an item whose image cannot be fetched is left out.
        var cached: Set<String> = []
        for entry in entries {
            let fileURL = imagesDirectory.appending(path: entry.imageFileName, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                cached.insert(entry.imageFileName)
                continue
            }

            do {
                var data = try await plexService.imageData(for: entry.imageURL)
                guard !Task.isCancelled else { return }
                if entry.blursImage {
                    guard let blurred = spoilerBlurred(data) else { continue }
                    data = blurred
                }
                try data.write(to: fileURL, options: .atomic)
                cached.insert(entry.imageFileName)
            } catch {
                guard !Task.isCancelled else { return }
                topShelfLogger.error("Top Shelf artwork failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !Task.isCancelled else { return }

        let snapshot = makeSnapshot(entries.filter { cached.contains($0.imageFileName) })
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            topShelfLogger.error("Could not write the Top Shelf snapshot: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Artwork for items that left Continue Watching.
        let files = (try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path(percentEncoded: false))) ?? []
        for file in files where !cached.contains(file) {
            try? fileManager.removeItem(at: imagesDirectory.appending(path: file, directoryHint: .notDirectory))
        }

        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// Blur Unwatched Episodes for a tile: the shelf draws plain files, so
    /// the blur is baked into the JPEG. Same strength as the in-app blur
    /// (`spoilerBlur`, 12 % of the short side). nil drops the tile rather
    /// than show the still sharp.
    private static func spoilerBlurred(_ data: Data) -> Data? {
        guard let image = CIImage(data: data) else { return nil }
        let radius = min(image.extent.width, image.extent.height) * 0.12
        let blurred = image
            .clampedToExtent()
            .applyingGaussianBlur(sigma: radius / 2)
            .cropped(to: image.extent)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CIContext().jpegRepresentation(of: blurred, colorSpace: colorSpace)
    }

    /// One Continue Watching section, exactly as Home shows it: started items
    /// and next episodes mixed, in `ContinueWatchingMerge`'s order.
    private static func makeSnapshot(_ entries: [Entry]) -> TopShelfSnapshot {
        guard !entries.isEmpty else { return TopShelfSnapshot(sections: []) }
        return TopShelfSnapshot(sections: [
            TopShelfSnapshot.Section(title: "Continue Watching", items: entries.map(\.item)),
        ])
    }
}

private extension TopShelfPublisher {
    struct Entry: Sendable {
        let item: TopShelfSnapshot.Item
        /// Authenticated Plex URL; only ever used by the app.
        let imageURL: URL
        /// The image is an unwatched episode's own still and Blur Unwatched
        /// Episodes is on.
        let blursImage: Bool
        let signature: String

        var imageFileName: String { item.imageFileName }

        @MainActor
        init?(item: PlexItem, plexService: PlexService) {
            guard let imagePath = Self.imagePath(for: item),
                  let imageURL = plexService.imageURL(
                      for: imagePath,
                      serverID: item.serverID,
                      width: TopShelfPublisher.imageWidth,
                      height: TopShelfPublisher.imageHeight
                  ),
                  let playURL = TopShelfLink.url(.play, for: item),
                  let displayURL = TopShelfLink.url(.open, for: item) else {
                return nil
            }

            // Plex art paths carry a timestamp, so new artwork means a new file
            // name and tvOS never shows a stale image cached under an old URL.
            // An unwatched episode's still only shows here when the show has
            // no backdrop; with Blur Unwatched Episodes on it is a separate,
            // blurred file, so toggling the setting never reuses the sharp one.
            let blursImage = UserPreferences.storedBlursUnwatchedEpisodes
                && item.isUnwatchedEpisode
                && imagePath == item.thumb
            let imageKey = "\(item.serverID ?? "")|\(imagePath)|\(TopShelfPublisher.imageWidth)x\(TopShelfPublisher.imageHeight)"
                + (blursImage ? "|blur" : "")
            let imageFileName = SHA256.hash(data: Data(imageKey.utf8))
                .prefix(16)
                .map { String(format: "%02x", $0) }
                .joined() + ".jpg"

            let progress = item.posterProgress.flatMap { $0 > 0 ? min($0, 1) : nil }
            self.item = TopShelfSnapshot.Item(
                id: item.id.storageKey,
                title: Self.title(for: item),
                imageFileName: imageFileName,
                progress: progress,
                playURL: playURL,
                displayURL: displayURL
            )
            self.imageURL = imageURL
            self.blursImage = blursImage
            self.signature = [
                self.item.id,
                self.item.title,
                imageFileName,
                progress.map { String(format: "%.3f", $0) } ?? "-",
            ].joined(separator: "|")
        }

        /// The show's backdrop for an episode, as the tvOS Home hero does: an
        /// episode still says little at Top Shelf size. Everything else uses
        /// its usual landscape art.
        private static func imagePath(for item: PlexItem) -> String? {
            if item.type == .episode {
                return item.grandparentArt ?? item.preferredLandscapePath
            }
            return item.preferredLandscapePath
        }

        /// "Show · S2 E3" for an episode, the plain title otherwise.
        private static func title(for item: PlexItem) -> String {
            let title = item.continueWatchingDisplayTitle
            guard item.type == .episode,
                  let season = item.parentIndex,
                  let episode = item.index else {
                return title
            }
            return "\(title) · S\(season) E\(episode)"
        }
    }
}
#endif
