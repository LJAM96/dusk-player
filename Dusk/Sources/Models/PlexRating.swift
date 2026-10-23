import Foundation

/// One entry of a title's `Rating` array: a score from one source.
/// `image` names the source (`imdb://image.rating`,
/// `rottentomatoes://image.rating.ripe`, `themoviedb://image.rating`), `type`
/// is `critic` or `audience`, `value` is on Plex's 0–10 scale.
struct PlexRating: Decodable, Hashable, Sendable {
    let image: String?
    let value: Double
    let type: String?

    init(image: String?, value: Double, type: String?) {
        self.image = image
        self.value = value
        self.type = type
    }

    /// How a detail page shows it: a short source name and the value in that
    /// source's own scale. Nil for a source Dusk cannot name.
    var display: (source: String, value: String)? {
        guard let image, let scheme = image.split(separator: ":").first?.lowercased() else { return nil }
        let percent = "\(Int((value * 10).rounded()))%"
        switch scheme {
        case "imdb":
            return ("IMDb", String(format: "%.1f", value))
        case "rottentomatoes":
            // ripe/rotten are the critics' Tomatometer; upright/spilled the
            // audience's Popcornmeter.
            return (type == "audience" || image.contains("upright") || image.contains("spilled")
                ? "RT Audience" : "Rotten Tomatoes", percent)
        case "themoviedb":
            return ("TMDB", percent)
        case "thetvdb":
            return ("TVDB", String(format: "%.1f", value))
        default:
            return nil
        }
    }

    /// The sources to show for a title: Plex's `Rating` array when the server
    /// sends one, else the two scalar ratings with their images.
    static func sources(for details: PlexMediaDetails) -> [PlexRating] {
        let all = details.ratings.isEmpty
            ? [
                details.rating.map { PlexRating(image: details.ratingImage, value: $0, type: "critic") },
                details.audienceRating.map { PlexRating(image: details.audienceRatingImage, value: $0, type: "audience") },
            ].compactMap { $0 }
            : details.ratings
        var seen = Set<String>()
        return all.filter { rating in
            guard let source = rating.display?.source else { return false }
            return seen.insert(source).inserted
        }
    }
}
