import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Dusk

@Suite("Intro auto-skip configuration", .serialized)
@MainActor
struct PlayerIntroAutoSkipTests {
    @Test func startupSyncDoesNotArmDefaultModeBeforeOffPreferenceIsApplied() {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .off
        defer { preferences.autoSkipIntroMode = previousMode }

        let marker = PlexMarker(
            id: 42,
            type: "intro",
            startTimeOffset: 5_000,
            endTimeOffset: 20_000
        )
        let engine = IntroAutoSkipPlaybackEngine(currentTime: 10)
        let viewModel = PlayerViewModel(engine: engine, markers: [marker])
        defer { viewModel.cleanup() }

        // The first timer sync can run before PlayerSessionView applies the
        // saved settings. It must not use PlayerViewModel's default mode.
        viewModel.sync()
        #expect(viewModel.autoSkipCountdownMarkerID == nil)

        viewModel.configureAutomaticTrackSelection(
            preferences: preferences,
            part: nil
        )
        #expect(viewModel.autoSkipIntroMode == .off)
        #expect(viewModel.autoSkipCountdownMarkerID == nil)

        preferences.autoSkipIntroMode = .always
        viewModel.configureAutomaticTrackSelection(preferences: preferences, part: nil)
        #expect(viewModel.autoSkipCountdownMarkerID == marker.id)

        preferences.autoSkipIntroMode = .off
        viewModel.configureAutomaticTrackSelection(preferences: preferences, part: nil)
        #expect(viewModel.autoSkipCountdownMarkerID == nil)
    }
}

@MainActor
private final class IntroAutoSkipPlaybackEngine: PlaybackEngine {
    let state: PlaybackState = .playing
    let currentTime: TimeInterval
    let duration: TimeInterval = 120
    let isBuffering = false
    let error: PlaybackError? = nil
    let videoEnhancementStatus = VideoEnhancementStatus.disabled
    var onPlaybackEnded: (@MainActor () -> Void)?
    let availableSubtitleTracks: [SubtitleTrack] = []
    let availableAudioTracks: [AudioTrack] = []
    let selectedSubtitleTrackID: Int? = nil
    let selectedAudioTrackID: Int? = nil
    private let player = AVPlayer()

    var playbackCoordinator: AVPlaybackCoordinator { player.playbackCoordinator }

    init(currentTime: TimeInterval) {
        self.currentTime = currentTime
    }

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
