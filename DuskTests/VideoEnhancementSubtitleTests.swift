import Foundation
import Testing
@testable import Dusk

@Suite("Video enhancement subtitle eligibility")
struct VideoEnhancementSubtitleTests {
    @Test(arguments: [VideoEnhancementMode.automatic, .enabled, .disabled])
    func embeddedTracksDoNotOverrideThePreference(mode: VideoEnhancementMode) throws {
        // Includes a Plex-selected/default/forced track: metadata alone does
        // not say what the local engine is actually displaying.
        let media = try mediaWithStreams(#"""
            {"id":2,"streamType":1,"codec":"h264","width":1280,"height":720,"frameRate":24},
            {"id":3,"streamType":3,"codec":"mov_text","selected":true,"default":true,"forced":true},
            {"id":4,"streamType":3,"codec":"pgs"}
            """#)
        let request = VideoEnhancementRequest.make(mode: mode, media: media, part: media.parts[0])
        #expect(request.mode == mode)
        #expect(request.disabledReason == nil)
        #expect(request.sourceWidth == 1280)
        #expect(request.sourceHeight == 720)
        #expect(request.frameRate == 24)
    }

    @Test func sidecarTracksDoNotDisableEnhancement() throws {
        let media = try mediaWithStreams(#"""
            {"id":3,"streamType":3,"codec":"srt","key":"/library/streams/3","selected":true}
            """#)
        let request = VideoEnhancementRequest.make(mode: .enabled, media: media, part: media.parts[0])
        #expect(request.isPotentiallyEnabled)
        #expect(request.disabledReason == nil)
    }

    @Test(arguments: [VideoEnhancementMode.automatic, .enabled])
    func avPlayerRequiresNativeRenderingOnlyWhileSubtitlesAreSelected(mode: VideoEnhancementMode) throws {
        let request = VideoEnhancementRequest(mode: mode)
        #expect(request.nativeSubtitleRenderingStatus(engine: .avPlayer, hasSelectedSubtitle: false) == nil)
        let status = try #require(request.nativeSubtitleRenderingStatus(engine: .avPlayer, hasSelectedSubtitle: true))
        #expect(status.state == .disabled)
        #expect(status.reason == "Native AVPlayer renderer required while subtitles are selected")
        // The request survives the temporary native-renderer fallback, so Off
        // in the subtitle picker immediately makes enhancement eligible again.
        #expect(request.nativeSubtitleRenderingStatus(engine: .avPlayer, hasSelectedSubtitle: false) == nil)
        #expect(request.mode == mode)
    }

    @Test(arguments: [false, true])
    func vlcCompositedSubtitlesRemainEligible(isSelected: Bool) {
        let request = VideoEnhancementRequest(mode: .enabled)
        #expect(request.nativeSubtitleRenderingStatus(engine: .vlcKit, hasSelectedSubtitle: isSelected) == nil)
        #expect(request.isPotentiallyEnabled)
    }

    @Test func explicitOffStillReportsThePreference() {
        let request = VideoEnhancementRequest.disabled
        #expect(request.nativeSubtitleRenderingStatus(engine: .avPlayer, hasSelectedSubtitle: true) == nil)
        #expect(request.nonRenderingStatus == .disabled)
    }

    @Test func hdrAndFrameRateLimitsKeepTheirOwnReasons() throws {
        let media = try mediaWithStreams(#"""
            {"id":2,"streamType":1,"codec":"hevc","bitDepth":10,"frameRate":24},
            {"id":3,"streamType":3,"codec":"pgs"}
            """#)
        let hdrRequest = VideoEnhancementRequest.make(mode: .automatic, media: media, part: media.parts[0])
        let requests = [
            hdrRequest,
            VideoEnhancementRequest(mode: .automatic, frameRate: 60),
            VideoEnhancementRequest(mode: .enabled, frameRate: 120),
        ]
        let reasons = ["Auto skips HDR", "Auto skips >50fps", "Disabled above 70fps"]
        for (request, reason) in zip(requests, reasons) {
            #expect(request.nativeSubtitleRenderingStatus(engine: .avPlayer, hasSelectedSubtitle: true) == nil)
            #expect(request.nonRenderingStatus.state == .unavailable)
            #expect(request.nonRenderingStatus.reason == reason)
        }
    }

    private func mediaWithStreams(_ streams: String) throws -> PlexMedia {
        try JSONDecoder().decode(PlexMedia.self, from: Data("""
            {"id":1,"Part":[{"id":1,"key":"/clip","Stream":[\(streams)]}]}
            """.utf8))
    }
}
