import Foundation

extension PlexItem {
    var posterProgress: Double? {
        MediaTextFormatter.progress(durationMs: duration, offsetMs: viewOffset)
    }

    /// The title under a poster. A season or episode on its own in a row
    /// (Recently Added, mostly) is known by its show — "Season 6" alone says
    /// nothing — so it takes the show's title and leaves the numbering to the
    /// subtitle (`standardPosterSubtitle`).
    var posterCardTitle: String {
        switch type {
        case .season:
            return parentTitle?.nilIfEmpty ?? title
        case .episode:
            return grandparentTitle?.nilIfEmpty ?? title
        default:
            return title
        }
    }

    var continueWatchingDisplayTitle: String {
        if type == .episode, let show = grandparentTitle {
            return show
        }
        return title
    }

    var continueWatchingDisplaySubtitle: String? {
        if isClip {
            return clipPosterSubtitle
        }
        if type == .episode {
            return MediaTextFormatter.seasonEpisodeLabel(season: parentIndex, episode: index) ?? title
        }
        return year.map(String.init)
    }

    /// Clip cards show their full upload date plus compact duration. Videos
    /// from the last week also include relative date context.
    var clipPosterSubtitle: String? {
        MediaTextFormatter.clipCardSubtitle(
            originallyAvailableAt: originallyAvailableAt,
            duration: duration,
            fallbackYear: year
        )
    }

    var standardPosterSubtitle: String? {
        if isClip {
            return clipPosterSubtitle
        }
        switch type {
        case .movie:
            return year.map(String.init)
        case .show:
            if let childCount {
                return MediaTextFormatter.seasonCount(childCount)?.lowercased()
            }
            return year.map(String.init)
        case .season:
            return title.nilIfEmpty ?? MediaTextFormatter.seasonEpisodeLabel(season: index, episode: nil)
        case .episode:
            return MediaTextFormatter.seasonEpisodeLabel(season: parentIndex, episode: index) ?? grandparentTitle
        case .collection:
            return collectionCountLabel
        default:
            return year.map(String.init)
        }
    }

    /// `12 movies`, `3 shows`, `1 item`: a collection's size in the words of
    /// what it holds.
    var collectionCountLabel: String? {
        guard type == .collection, let childCount else { return nil }
        return Self.collectionCountLabel(childCount, subtype: subtype)
    }

    static func collectionCountLabel(_ count: Int, subtype: String?) -> String {
        let noun: (String, String) = switch subtype {
        case "movie": ("movie", "movies")
        case "show": ("show", "shows")
        case "episode": ("episode", "episodes")
        case "clip": ("video", "videos")
        default: ("item", "items")
        }
        return "\(count) \(count == 1 ? noun.0 : noun.1)"
    }

    /// Home's poster rows show a year under movies and shows, but a season or
    /// episode needs its numbering there because its title is the show's
    /// ("S6 · E3": the long form does not fit under a poster).
    var hubPosterSubtitle: String? {
        switch type {
        case .season:
            return standardPosterSubtitle
        case .episode:
            return MediaTextFormatter.compactSeasonEpisodeLabel(season: parentIndex, episode: index)
                ?? standardPosterSubtitle
        case .collection:
            return collectionCountLabel
        default:
            return year.map(String.init)
        }
    }

    var filmographyPosterSubtitle: String? {
        switch type {
        case .movie:
            return year.map(String.init)
        case .show:
            let parts = [
                year.map(String.init),
                childCount.flatMap { MediaTextFormatter.seasonCount($0) },
            ]
            .compactMap { $0 }

            return parts.joined(separator: " · ").nilIfEmpty
        default:
            return nil
        }
    }

    /// Artwork always comes from the item's own server: a merged row mixes
    /// items from several servers, and the paths are only valid on theirs.
    @MainActor
    func posterImageURL(plexService: PlexService, width: Int, height: Int) -> URL? {
        plexService.imageURL(for: preferredPosterPath, serverID: serverID, width: width, height: height)
    }

    @MainActor
    func fallbackPosterImageURL(plexService: PlexService, width: Int, height: Int) -> URL? {
        plexService.imageURL(for: fallbackPosterPath, serverID: serverID, width: width, height: height)
    }

    @MainActor
    func landscapeImageURL(plexService: PlexService, width: Int, height: Int) -> URL? {
        plexService.imageURL(for: preferredLandscapePath, serverID: serverID, width: width, height: height)
    }
}

/// The text and artwork of a featured hero: Home's cinematic hero and the
/// tvOS featured hero on Home and the library pages.
extension PlexItem {
    /// An episode's own title under its show's. `nil` when it would repeat
    /// the hero's title.
    var featuredEpisodeTitle: String? {
        guard type == .episode else { return nil }
        return title == continueWatchingDisplayTitle ? nil : title
    }

    /// `S2 · E5 · 31m left`, `2024 · 2h 10m`.
    var featuredMetadata: [String] {
        var parts: [String] = []

        switch type {
        case .episode:
            if let label = MediaTextFormatter.seasonEpisodeLabel(
                season: parentIndex,
                episode: index
            ) {
                parts.append(label)
            }
        case .movie:
            if let year {
                parts.append(String(year))
            }
        default:
            break
        }

        if let durationText = featuredDurationText {
            parts.append(durationText)
        }

        return parts
    }

    var featuredSummary: String? {
        guard let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return nil
        }

        return summary
    }

    /// Full-screen artwork: an episode or season shows its show's.
    var featuredBackgroundPath: String? {
        switch type {
        case .episode:
            return grandparentArt ?? art ?? banner ?? thumb ?? grandparentThumb
        case .season:
            return art ?? banner ?? thumb ?? parentThumb
        default:
            return preferredLandscapePath
        }
    }

    private var featuredDurationText: String? {
        guard let duration, duration > 0 else { return nil }

        if let viewOffset, viewOffset > 0 {
            let remaining = max(duration - viewOffset, 0)
            guard let remainingText = MediaTextFormatter.playbackDuration(milliseconds: remaining) else {
                return nil
            }
            return remaining > 0 ? "\(remainingText) left" : remainingText
        }

        return MediaTextFormatter.playbackDuration(milliseconds: duration)
    }
}

/// Shared "video row" decision for hub-shaped rows (Home hubs, search result
/// groups, hub item grids): a non-empty row consisting entirely of clips
/// renders as a 16:9 carousel/grid; anything mixed or non-clip keeps the 2:3
/// poster layout.
extension Collection where Element == PlexItem {
    var isAllClips: Bool {
        !isEmpty && allSatisfy(\.isClip)
    }
}
