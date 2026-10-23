import Foundation

extension PlaybackCoordinator {
    var isAV1ServerSession: Bool {
        guard let debugInfo, case .serverStream = debugInfo.decision else { return false }
        return StreamResolver.containsAV1(debugInfo.media)
    }

    func scheduleAV1ServerTrackChange() {
        let previous = spatialAudioTransitionTask
        previous?.cancel()
        spatialAudioTransitionTask = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.rebuildAV1ServerSession(reason: "AV1 server track selection changed")
        }
    }

    /// Decoder fallback and track changes share the same uncapped conversion.
    /// Plex burns bitmap subtitles only when selected; the local engine never
    /// receives HDR AV1 it cannot decode or an unsupported audio track.
    func rebuildAV1ServerSession(reason: String) async {
        guard !didFinalizeCurrentSession, !activePlaybackUsesLocalDownload,
              !isSwitchingQuality,
              let details = activeItemDetails, let debugInfo, let ratingKey,
              let mediaIndex = details.media.firstIndex(where: { $0.id == debugInfo.media.id }) else { return }
        isSwitchingQuality = true
        defer { isSwitchingQuality = false }
        let previousSelection = remuxTrackSelection
        let presentationID = playerPresentationID
        let sessionID = UUID().uuidString
        let serverID = activePlaybackServerID
        let position = max(engine?.currentTime ?? 0, TimeInterval(lastReportedTimeMs) / 1000.0, playbackSource?.startPosition ?? 0)
        let wasPlaying = engine?.state != .paused
        do {
            try await plexService.selectStreams(
                partID: debugInfo.part.id, audioStreamID: activeAudioStreamID,
                subtitleStreamID: activeSubtitleStreamID ?? 0, serverID: serverID
            )
            let result = try await plexService.serverStreamURL(
                ratingKey: ratingKey, mediaIndex: mediaIndex,
                sessionIdentifier: activePlaybackSessionIdentifier ?? UUID().uuidString,
                transcodeSessionID: sessionID, audioStreamID: activeAudioStreamID,
                subtitleStreamID: activeSubtitleStreamID, forceVideoTranscode: true, serverID: serverID
            )
            guard !Task.isCancelled, !didFinalizeCurrentSession,
                  playerPresentationID == presentationID else {
                stopTranscodeSessionInBackground(sessionID, serverID: serverID)
                return
            }
            guard case .transcodeAvailable = result.outcome else {
                stopTranscodeSessionInBackground(sessionID, serverID: serverID)
                if let previousSelection {
                    activeAudioStreamID = previousSelection.audioStreamID
                    activeSubtitleStreamID = previousSelection.subtitleStreamID
                }
                presentQualitySwitchError("Plex could not prepare a compatible AV1 stream.")
                return
            }
            if let previous = activeTranscodeSessionID {
                stopTranscodeSessionInBackground(previous, serverID: serverID)
            }
            activeTranscodeSessionID = sessionID
            remuxAudioConversion = nil
            activateReplacementAttempt(
                transitionLabel: reason, attemptID: UUID(), details: details, ratingKey: ratingKey,
                media: debugInfo.media, part: debugInfo.part, playbackURL: result.url,
                sanitizedURL: plexService.sanitizedPlaybackURLString(for: result.url),
                playbackDecision: .serverStream, engineType: .avPlayer, resolverReason: reason,
                videoEnhancementRequest: .disabled, startPosition: position, shouldAutoPlay: wasPlaying
            )
        } catch {
            stopTranscodeSessionInBackground(sessionID, serverID: serverID)
            if !Task.isCancelled, playerPresentationID == presentationID {
                if let previousSelection {
                    activeAudioStreamID = previousSelection.audioStreamID
                    activeSubtitleStreamID = previousSelection.subtitleStreamID
                }
                presentQualitySwitchError(error.localizedDescription)
            }
        }
    }
}
