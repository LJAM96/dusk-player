import Foundation

/// The account's video playlists across every connected server, shared by the
/// Playlists tab, its detail pages and the Add to Playlist sheet so an edit in
/// one shows everywhere (and a first playlist created from a context menu
/// brings the tab in). `PlexService+Playlists` loads it; screens mutate it only
/// through the store's edit helpers after the server accepted the change.
///
/// Loaded once per `ServerContentRevision` (connected servers, priority,
/// profile). A server that does not answer keeps whatever it had before rather
/// than emptying the list.
@MainActor
@Observable
final class PlaylistStore {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var playlistsByServer: [String: [PlexPlaylist]] = [:]
    private(set) var serverOrder: [String] = []
    private(set) var state: State = .idle
    @ObservationIgnored private(set) var loadedRevision: ServerContentRevision?

    /// Every playlist, A–Z like Plex lists them; same-titled playlists keep
    /// server priority order.
    var playlists: [PlexPlaylist] {
        let ordered = serverOrder.flatMap { playlistsByServer[$0] ?? [] }
        return ordered.enumerated().sorted { lhs, rhs in
            let order = lhs.element.title.localizedStandardCompare(rhs.element.title)
            return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
        }.map(\.element)
    }

    var hasPlaylists: Bool {
        playlistsByServer.values.contains { !$0.isEmpty }
    }

    /// Regular (non-smart) playlists on one server, most recently updated
    /// first: the Add to Playlist targets for an item from that server.
    func editablePlaylists(serverID: String?) -> [PlexPlaylist] {
        guard let serverID else { return [] }
        return (playlistsByServer[serverID] ?? [])
            .filter { !$0.smart }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    func playlist(id: PlexItemID) -> PlexPlaylist? {
        guard let serverID = id.serverID else { return nil }
        return playlistsByServer[serverID]?.first { $0.ratingKey == id.ratingKey }
    }

    /// True when the playlists are worth asking each server about more than one.
    var spansMultipleServers: Bool {
        playlistsByServer.filter { !$0.value.isEmpty }.count > 1
    }

    // MARK: - Loading (PlexService+Playlists)

    func beginLoad(revision: ServerContentRevision) {
        if loadedRevision?.profileID != revision.profileID {
            playlistsByServer = [:]
        }
        // Servers that are no longer connected drop out.
        playlistsByServer = playlistsByServer.filter { revision.serverIDs.contains($0.key) }
        serverOrder = revision.serverIDs
        loadedRevision = revision
        if state != .loaded {
            state = .loading
        }
    }

    func commit(_ playlists: [PlexPlaylist], serverID: String) {
        playlistsByServer[serverID] = playlists
    }

    func finishLoad(failure: String?) {
        if let failure, !hasPlaylists {
            state = .failed(failure)
        } else {
            state = .loaded
        }
    }

    func reset() {
        playlistsByServer = [:]
        serverOrder = []
        loadedRevision = nil
        state = .idle
    }

    // MARK: - Edits

    func upsert(_ playlist: PlexPlaylist) {
        guard let serverID = playlist.serverID else { return }
        var list = playlistsByServer[serverID] ?? []
        if let index = list.firstIndex(where: { $0.ratingKey == playlist.ratingKey }) {
            list[index] = playlist
        } else {
            list.append(playlist)
        }
        playlistsByServer[serverID] = list
        if !serverOrder.contains(serverID) {
            serverOrder.append(serverID)
        }
    }

    func remove(_ id: PlexItemID) {
        guard let serverID = id.serverID else { return }
        playlistsByServer[serverID]?.removeAll { $0.ratingKey == id.ratingKey }
    }
}
