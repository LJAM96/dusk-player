import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Dusk

@Suite("Automatic playback recovery presentation")
@MainActor
struct PlaybackFallbackTests {
    @Test(arguments: [
        #""DOVIPresent":true,"DOVIProfile":5,"DOVIBLCompatID":0,"bitDepth":10"#,
        #""DOVIPresent":true,"DOVIProfile":8,"DOVIBLCompatID":1"#,
        #""colorTrc":"smpte2084""#,
        #""colorTrc":"arib-std-b67""#,
    ])
    func declinedHDRTrackChangesKeepTheLoadedRemux(videoFields: String) async throws {
        let playback = PlaybackCoordinator(plexService: PlexService())
        let details = try JSONDecoder().decode(PlexMediaDetails.self, from: Data("""
            {"ratingKey":"1","key":"/library/metadata/1","type":"movie","title":"HDR",
             "Media":[{"id":1,"container":"mkv","Part":[{"id":2,"key":"/clip.mkv","Stream":[
               {"id":3,"streamType":1,"codec":"hevc",\(videoFields)}
             ]}]}]}
            """.utf8))
        let media = try #require(details.media.first)
        let url = try #require(URL(string: "https://example.invalid/remux.m3u8"))
        let engine = FailedPlaybackEngine(state: .playing)
        let attemptID = UUID()
        playback.engine = engine
        playback.ratingKey = "1"
        playback.activeItemDetails = details
        playback.activeTranscodeSessionID = "working-remux"
        playback.remuxTrackSelection = ExplicitTrackSelection(audioStreamID: 4, subtitleStreamID: nil)
        playback.debugInfo = PlaybackDebugInfo(
            title: "HDR", engine: .avPlayer, decision: .spatialAudio,
            media: media, part: media.parts[0], attemptID: attemptID,
            resolverReason: "HDR remux", sanitizedPlaybackURL: url.absoluteString
        )
        playback.playbackSource = PlaybackSource(
            url: url, startPosition: 42,
            context: PlaybackAttemptContext(
                attemptID: attemptID, title: "HDR", ratingKey: "1", engine: .avPlayer,
                resolverReason: "HDR remux", mediaID: 1, partID: 2,
                sanitizedPlaybackURL: url.absoluteString
            )
        )
        let presentationID = playback.playerPresentationID
        // Exercise repeated refused On/Off changes without opening media or
        // contacting Plex. The loaded session and its confirmed tracks win.
        for subtitleID: Int? in [5, nil, 5, nil] {
            playback.activeAudioStreamID = 6
            playback.activeSubtitleStreamID = subtitleID
            await playback.leaveSpatialAudioRemux(reason: "declined", keepsExplicitTracks: true)
            #expect(playback.engine === engine)
            #expect(playback.playerPresentationID == presentationID)
            #expect(playback.playbackSource?.url == url)
            #expect(playback.activeTranscodeSessionID == "working-remux")
            #expect(playback.activeAudioStreamID == 4)
            #expect(playback.activeSubtitleStreamID == nil)
            #expect(playback.qualitySwitchError != nil)
        }
    }

    @Test func remuxErrorsStayLoadingUntilRecoveryIsExhausted() {
        let playback = PlaybackCoordinator(plexService: PlexService())
        playback.showPlayer = true
        playback.engine = FailedPlaybackEngine()
        playback.startDirectPlayFallbackWatch()
        defer { playback.cancelDirectPlayFallbackWatch() }

        // Remuxes arm this watch too; no direct-play-only presentation gate.
        #expect(playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .recovering)
        playback.isAutomaticDirectPlayFallbackAvailable = false
        playback.isAutomaticDirectPlayFallbackActive = true
        #expect(playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .recovering)
        playback.cancelDirectPlayFallbackWatch()
        #expect(!playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .hidden)
    }

    @Test func exhaustedFallbackRevealsTerminalError() async {
        let playback = PlaybackCoordinator(plexService: PlexService())
        playback.showPlayer = true
        playback.engine = FailedPlaybackEngine()
        playback.isAutomaticDirectPlayFallbackAvailable = true
        playback.isAutomaticDirectPlayFallbackActive = true
        // No active item means no replacement can be prepared.
        await playback.performDirectPlayServerStreamFallback()
        #expect(!playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .hidden)
    }

    @Test func dv7RetryKeepsTheReplacementFallbackArmed() async throws {
        let playback = PlaybackCoordinator(plexService: PlexService())
        let media = try JSONDecoder().decode(PlexMedia.self, from: Data(#"""
            {"id":1,"container":"mkv","Part":[{"id":2,"key":"/clip.mkv","Stream":[
              {"id":3,"streamType":1,"codec":"hevc","DOVIProfile":7,"DOVILevel":6,"DOVIBLCompatID":6}
            ]}]}
            """#.utf8))
        let url = try #require(URL(string: "https://example.invalid/clip.m3u8"))
        let conversion = try #require(StreamResolver.dolbyVision7ConversionTarget(in: media))
        let attemptID = UUID()
        playback.showPlayer = true
        playback.engine = FailedPlaybackEngine()
        playback.debugInfo = PlaybackDebugInfo(
            title: "DV7", engine: .avPlayer, decision: .spatialAudio,
            media: media, part: media.parts[0], attemptID: attemptID,
            resolverReason: "DV7 remux", sanitizedPlaybackURL: url.absoluteString
        )
        playback.playbackSource = PlaybackSource(
            url: url, startPosition: nil,
            context: PlaybackAttemptContext(
                attemptID: attemptID, title: "DV7", ratingKey: "1",
                engine: .avPlayer, resolverReason: "DV7 remux", mediaID: 1,
                partID: 2, sanitizedPlaybackURL: url.absoluteString
            ),
            dolbyVision7Conversion: conversion
        )
        playback.isAutomaticDirectPlayFallbackAvailable = true
        playback.isAutomaticDirectPlayFallbackActive = true

        // A queued track rebuild replaces the failed engine while the DV7
        // retry waits for it. Exercise the real retry/cleanup across that await
        // without loading media or contacting Plex.
        playback.spatialAudioTransitionTask = Task { @MainActor in
            playback.engine = FailedPlaybackEngine()
            playback.playerPresentationID = UUID()
            playback.startDirectPlayFallbackWatch()
        }
        defer { playback.cancelDirectPlayFallbackWatch() }
        await playback.performDirectPlayServerStreamFallback()
        #expect(playback.isDolbyVision7ConversionSuppressed)
        #expect(playback.isAutomaticDirectPlayFallbackAvailable)
        #expect(playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .recovering)
    }
}

@MainActor
private final class FailedPlaybackEngine: PlaybackEngine {
    let state: PlaybackState
    var error: PlaybackError? { state == .error ? .unknown("The decoder failed.") : nil }
    init(state: PlaybackState = .error) { self.state = state }
    let currentTime: TimeInterval = 0
    let duration: TimeInterval = 0
    let isBuffering = false
    let videoEnhancementStatus = VideoEnhancementStatus.disabled
    var onPlaybackEnded: (@MainActor () -> Void)?
    let availableSubtitleTracks: [SubtitleTrack] = []
    let availableAudioTracks: [AudioTrack] = []
    let selectedSubtitleTrackID: Int? = nil
    let selectedAudioTrackID: Int? = nil
    var playbackCoordinator: AVPlaybackCoordinator { player.playbackCoordinator }
    private let player = AVPlayer()

    func load(source: PlaybackSource) {}
    func configureVideoEnhancement(_ request: VideoEnhancementRequest) {}
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to position: TimeInterval) {}
    func setPlaybackRate(_ rate: Float) {}
    func configureCoordinatedPlayback(itemIdentifier: String?) {}
    func recoverFromStall() {}
    func handleReturnToForeground() {}
    func selectSubtitleTrack(_ track: SubtitleTrack?) {}
    func selectAudioTrack(_ track: AudioTrack) {}
    func makePlayerView() -> AnyView { AnyView(EmptyView()) }
}
