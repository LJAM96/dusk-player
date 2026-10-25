import Foundation

/// Where the Watchlist row sits among Home's arranged hubs.
///
/// The row is always below the hero / Continue Watching (and Live TV): the
/// result is an index into `hubs` only, never above them.
///
/// - Plex's own Home layout wins when the account customized it (Plex Web's
///   `homeSettings.hubs`): hidden there means hidden here, and otherwise the
///   row follows the nearest row before it in Plex's list that Home also
///   shows. With none of those before it, it leads the hubs.
/// - Otherwise it goes after the first Recently Added rows (at most two in a
///   row), no lower than the fourth row: near the top without pushing new
///   arrivals down.
///
/// Hubs are already in the account's library order (`HomeHubArrangement`),
/// so anchoring to a hub follows Library Order too.
enum HomeWatchlistPlacement {
    /// The index in `hubs` the row is inserted before (`hubs.count` = after
    /// every hub), or nil when Plex's layout hides the Watchlist.
    static func index(in hubs: [PlexHub], plexHomeHubs: [PlexHomeHubSetting]?) -> Int? {
        if let plexHomeHubs, let position = plexHomeHubs.firstIndex(where: \.isWatchlist) {
            if plexHomeHubs[position].isHidden { return nil }
            for preceding in plexHomeHubs[..<position].reversed() where !preceding.isHidden {
                if let anchor = hubs.firstIndex(where: { matches($0, preceding) }) {
                    return anchor + 1
                }
            }
            return 0
        }
        return defaultIndex(in: hubs)
    }

    static let defaultMaxIndex = 3

    static func defaultIndex(in hubs: [PlexHub]) -> Int {
        guard !hubs.isEmpty else { return 0 }
        guard let recentlyAdded = hubs.firstIndex(where: isRecentlyAdded) else {
            return 1
        }
        // Past the first two Recently Added rows when they follow each other
        // (Movies, then TV on a default PMS Home).
        var end = recentlyAdded + 1
        if end < hubs.count, isRecentlyAdded(hubs[end]) {
            end += 1
        }
        return min(end, defaultMaxIndex)
    }

    private static func isRecentlyAdded(_ hub: PlexHub) -> Bool {
        [hub.hubIdentifier, hub.key].contains { $0?.lowercased().contains("recentlyadded") == true }
    }

    private static func matches(_ hub: PlexHub, _ setting: PlexHomeHubSetting) -> Bool {
        // A merged row carries its representative server's identifier; the
        // other servers' copies of the row cannot be told apart from it.
        guard hub.hubIdentifier == setting.hubIdentifier else { return false }
        guard let machineIdentifier = setting.machineIdentifier else { return true }
        return hub.serverID == machineIdentifier || hub.sources.contains { $0.serverID == machineIdentifier }
    }
}
