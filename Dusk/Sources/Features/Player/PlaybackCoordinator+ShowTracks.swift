import Foundation
import OSLog

extension PlaybackCoordinator {
    /// Called only by explicit picker/download actions, including selecting Off
    /// again. Engine discovery, automatic selection and recovery never save.
    func rememberShowTrackChoice(type: PlexStreamType, streamID: Int?) {
        guard activeLiveTVContext == nil,
              activeItemDetails?.type == .episode,
              let scope = activeShowTrackScope,
              scope.profileID == plexService.activeProfileID,
              let part = debugInfo?.part else { return }
        var remembered = showTrackPreferenceStore.preferences(for: scope) ?? ShowTrackPreferences()
        if type == .subtitle, streamID == nil {
            remembered.subtitles = .off
        } else {
            guard let streamID,
                  let stream = part.streams.first(where: { $0.streamType == type && $0.id == streamID }),
                  let descriptor = ShowTrackDescriptor(stream: stream) else { return }
            if type == .audio {
                remembered.audio = descriptor
            } else if type == .subtitle {
                remembered.subtitles = .track(descriptor)
            } else {
                return
            }
        }
        showTrackPreferenceStore.save(remembered, for: scope)

        // Remux changes already PUT the complete selection before rebuilding
        // HLS (including On → Off → On). Keep that authoritative path intact.
        guard !usesServerTrackSelection, !activePlaybackUsesLocalDownload else { return }
        syncShowStreamsToPlex(
            partID: part.id,
            audioStreamID: type == .audio ? streamID : nil,
            subtitleStreamID: type == .subtitle ? (streamID ?? 0) : nil,
            serverID: scope.serverID
        )
    }

    /// Also used after PiP re-presentation: the startup one-shot may already
    /// have been consumed, but the show's choice must still beat global defaults.
    func rememberedShowTrackSelection() -> ExplicitTrackSelection? {
        guard activeLiveTVContext == nil,
              activeItemDetails?.type == .episode,
              let scope = activeShowTrackScope,
              scope.profileID == plexService.activeProfileID,
              let part = debugInfo?.part,
              let remembered = showTrackPreferenceStore.preferences(for: scope),
              remembered.hasMatch(in: part) else { return nil }
        return ExplicitTrackSelection(
            audioStreamID: activeAudioStreamID,
            subtitleStreamID: activeSubtitleStreamID
        )
    }

    func syncShowStreamsToPlex(partID: Int, audioStreamID: Int?, subtitleStreamID: Int?, serverID: String) {
        let write = plexService.enqueueStreamSelection(
            partID: partID,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            serverID: serverID
        )
        Task { @MainActor in
            do {
                try await write.value
            } catch {
                // Local preferences survive offline/auth/server failures. Never
                // let a best-effort Plex write interrupt direct playback.
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dusk", category: "ShowTracks")
                    .notice("Could not sync show track selection: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
