import Foundation
import Testing
@testable import Dusk

@Suite("TrueHD routing with Dusk's VLCKit build")
@MainActor
struct TrueHDAudioRoutingTests {
    // MARK: - Decodability

    @Test func trueHDIsDecodableOnlyWithDusksBuild() {
        for codec in ["truehd", "TrueHD", "mlp"] {
            #expect(!PlayerViewModel.isLocallyUndecodableAudioCodec(codec, decodesTrueHD: true))
            #expect(PlayerViewModel.isLocallyUndecodableAudioCodec(codec, decodesTrueHD: false))
        }
        for codec in ["eac3", "ac3", "dca", "flac", nil] {
            #expect(!PlayerViewModel.isLocallyUndecodableAudioCodec(codec, decodesTrueHD: false))
        }
    }

    // MARK: - Direct-play preselection

    @Test func preselectionOpensOnTrueHDOnTVOS() throws {
        let part = try makePart(audio: bluRayAudio)
        let position = PlayerViewModel.preferredAudioStreamPosition(
            inPart: part,
            preferredLanguage: nil,
            decodesTrueHD: true
        )
        #if os(tvOS)
        // Lossless ranks top on tvOS: discrete 7.1 PCM over HDMI.
        #expect(position == 0)
        #else
        // iPhone/iPad downmix to stereo either way, so the lossy sibling wins.
        #expect(position == 1)
        #endif
    }

    @Test func stockBuildNeverPreselectsTrueHD() throws {
        let part = try makePart(audio: bluRayAudio)
        let position = PlayerViewModel.preferredAudioStreamPosition(
            inPart: part,
            preferredLanguage: nil,
            decodesTrueHD: false
        )
        #expect(position == 1)
    }

    // MARK: - Startup remux pick

    @Test func remuxDecisionKeepsTheCopyableSibling() throws {
        let part = try makePart(audio: bluRayAudio)
        let stream = PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: nil)
        #expect(stream?.id == 3)
    }

    @Test func remuxDecisionPrefersEAC3AtmosOverTrueHDAtmos() throws {
        let part = try makePart(audio: """
            { "id": 2, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "default": true, "displayTitle": "English (TrueHD 7.1 Atmos)" },
            { "id": 3, "streamType": 2, "codec": "eac3", "channels": 8, "languageCode": "eng", "profile": "dolby digital plus + dolby atmos", "displayTitle": "English (EAC3 7.1 Atmos)" }
            """)
        let stream = try #require(PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: nil))
        #expect(stream.id == 3)
        #expect(StreamResolver.isSpatialAudioCandidate(stream))
    }

    @Test func remuxDecisionFallsBackToTrueHDWhenItIsTheOnlyTrack() throws {
        let part = try makePart(audio: trueHDOnlyAudio)
        let stream = PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: nil)
        #expect(stream?.id == 2)
        #expect(PlayerViewModel.isTrueHDAudioCodec(stream?.codec))
    }

    @Test func hdrRemuxStillQualifiesForTrueHDPlusAC3() throws {
        let media = try makeMedia(video: #""colorTrc": "smpte2084""#, audio: bluRayAudio)
        let part = media.parts[0]
        let remuxAudio = PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: nil)
        let blocker = StreamResolver.hdrVideoRemuxBlocker(
            media: media,
            decision: StreamResolver.evaluate(media: media),
            audioStream: remuxAudio,
            subtitleStream: nil,
            displaySupportsHDR: true
        )
        #expect(blocker == nil)
    }

    // MARK: - Converted TrueHD remux gate

    @Test func hdrTrueHDOnlyFileKeepsTheConvertedRemux() throws {
        let media = try makeMedia(video: #""colorTrc": "smpte2084""#, audio: trueHDOnlyAudio)
        #expect(convertedBlocker(for: media) == nil)
    }

    @Test func hdrGateHonoursDisplayAndSetting() throws {
        let media = try makeMedia(video: #""colorTrc": "smpte2084""#, audio: trueHDOnlyAudio)
        #if os(tvOS)
        #expect(convertedBlocker(for: media, displaySupportsHDR: false) != nil)
        #expect(convertedBlocker(for: media, hdrVideoRemuxEnabled: false) != nil)
        #else
        #expect(convertedBlocker(for: media, displaySupportsHDR: false, spatialAudioRemuxEnabled: false) != nil)
        #expect(convertedBlocker(for: media, hdrVideoRemuxEnabled: false, spatialAudioRemuxEnabled: false) != nil)
        #endif
    }

    @Test func sdrTrueHDOnlyFileDecodesLocallyOnTVOS() throws {
        let media = try makeMedia(video: #""colorTrc": "bt709""#, audio: trueHDOnlyAudio)
        #if os(tvOS)
        #expect(convertedBlocker(for: media) != nil)
        #else
        // Spatial audio for AirPods outweighs a stereo downmix of the lossless track.
        #expect(convertedBlocker(for: media) == nil)
        #expect(convertedBlocker(for: media, spatialAudioRemuxEnabled: false) != nil)
        #endif
    }

    @Test func bitmapSubtitleKeepsTrueHDLocal() throws {
        let media = try makeMedia(
            video: #""colorTrc": "smpte2084""#,
            audio: trueHDOnlyAudio,
            subtitleCodec: "pgs"
        )
        #expect(convertedBlocker(for: media, subtitleID: 9, spatialAudioRemuxEnabled: false) != nil)
    }

    // MARK: - Helpers

    private let bluRayAudio = """
        { "id": 2, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "default": true, "displayTitle": "English (TrueHD 7.1)" },
        { "id": 3, "streamType": 2, "codec": "ac3", "channels": 6, "languageCode": "eng", "displayTitle": "English (AC3 5.1)" }
        """

    private let trueHDOnlyAudio = """
        { "id": 2, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "default": true, "displayTitle": "English (TrueHD 7.1 Atmos)" }
        """

    private func convertedBlocker(
        for media: PlexMedia,
        subtitleID: Int? = nil,
        displaySupportsHDR: Bool = true,
        hdrVideoRemuxEnabled: Bool = true,
        spatialAudioRemuxEnabled: Bool = true
    ) -> String? {
        let streams = media.parts[0].streams
        guard let audio = streams.first(where: { $0.streamType == .audio }) else {
            return "no audio"
        }
        return StreamResolver.convertedTrueHDRemuxBlocker(
            media: media,
            decision: StreamResolver.evaluate(media: media),
            audioStream: audio,
            subtitleStream: subtitleID.flatMap { id in streams.first { $0.id == id } },
            displaySupportsHDR: displaySupportsHDR,
            hdrVideoRemuxEnabled: hdrVideoRemuxEnabled,
            spatialAudioRemuxEnabled: spatialAudioRemuxEnabled
        )
    }

    private func makePart(audio: String) throws -> PlexMediaPart {
        try makeMedia(video: #""colorTrc": "bt709""#, audio: audio).parts[0]
    }

    private func makeMedia(
        video: String,
        audio: String,
        subtitleCodec: String? = nil
    ) throws -> PlexMedia {
        let subtitle = subtitleCodec.map { #", { "id": 9, "streamType": 3, "codec": "\#($0)" }"# } ?? ""
        let json = """
        {
            "id": 10,
            "container": "mkv",
            "Part": [{
                "id": 20,
                "key": "/library/parts/20/file.mkv",
                "container": "mkv",
                "Stream": [
                    { "id": 1, "streamType": 1, "codec": "hevc", "bitDepth": 10, "frameRate": 23.976, \(video) },
                    \(audio)\(subtitle)
                ]
            }]
        }
        """
        return try JSONDecoder().decode(PlexMedia.self, from: Data(json.utf8))
    }
}
