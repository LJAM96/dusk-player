import Foundation
import Testing
@testable import Dusk

@Suite("Dolby Vision 7 init segment rewrite")
struct DolbyVision7InitRewriterTests {
    private let target = DolbyVisionConfiguration(
        profile: 7, level: 6, blSignalCompatibilityID: 6,
        lumaSampleRate: nil, lumaPictureSize: nil, bitrateKbps: nil
    ).convertedToProfile81()

    /// DOVIDecoderConfigurationRecord for 8.1 level 6, written out by hand:
    /// version 1.0; profile 8 (7 bits) | level 6 (6 bits) | rpu 1 | el 0 |
    /// bl 1 = 0001000 000110 1 0 1 = 0x1035; compatibility ID 1 in the top
    /// nibble = 0x10; 19 reserved zero bytes.
    private let expectedDvvC: [UInt8] = [0, 0, 0, 32] + Array("dvvC".utf8)
        + [1, 0, 0x10, 0x35, 0x10] + [UInt8](repeating: 0, count: 19)

    @Test func profile7EntryBecomesHvc1WithProfile81DvvC() throws {
        let (data, info) = try DolbyVision7InitRewriter.rewrite(Data(initSegment()), target: target)

        let expected = initSegment(
            brands: ["isom", "iso6", "mp41", "dby1"],
            videoChildren: [hvcC(lengthSizeMinusOne: 3), colr()] + [expectedDvvC]
        )
        #expect([UInt8](data) == expected)
        #expect(info == FMP4InitInfo(
            video: FMP4VideoTrackInfo(trackID: 1, nalLengthSize: 4),
            trexDefaults: [
                1: FMP4TrackDefaults(defaultSampleDuration: 1001, defaultSampleSize: 0, defaultSampleFlags: 0x0001_0000),
                2: FMP4TrackDefaults(defaultSampleDuration: 1536, defaultSampleSize: 0, defaultSampleFlags: 0x0200_0000),
            ]
        ))
    }

    @Test func configurationBoxMatchesTheDolbyLayout() {
        #expect(DolbyVisionSignaling.configurationBox(target) == expectedDvvC)
    }

    @Test func dvh1IsRenamedAndExistingBrandKept() throws {
        let input = initSegment(brands: ["isom", "dby1"], videoEntry: "dvh1", videoChildren: [hvcC(lengthSizeMinusOne: 1)])
        let (data, info) = try DolbyVision7InitRewriter.rewrite(Data(input), target: target)
        let expected = initSegment(brands: ["isom", "dby1"], videoChildren: [hvcC(lengthSizeMinusOne: 1), expectedDvvC])
        #expect([UInt8](data) == expected)
        #expect(info.video.nalLengthSize == 2)
    }

    @Test func version1TrackHeaderTrackID() throws {
        let (_, info) = try DolbyVision7InitRewriter.rewrite(Data(initSegment(videoTrackHeaderVersion: 1, videoTrackID: 7)), target: target)
        #expect(info.video.trackID == 7)
    }

    @Test func hev1Throws() {
        #expect(isUnsupportedInit { try DolbyVision7InitRewriter.rewrite(Data(initSegment(videoEntry: "hev1")), target: target) })
        #expect(isUnsupportedInit { try DolbyVision7InitRewriter.rewrite(Data(initSegment(videoEntry: "dvhe")), target: target) })
    }

    @Test func missingHvcCThrows() {
        let input = initSegment(videoChildren: [colr()])
        #expect(isUnsupportedInit { try DolbyVision7InitRewriter.rewrite(Data(input), target: target) })
    }

    @Test func twoVideoTracksThrow() {
        let input = initSegment(extraTrak: videoTrak(trackID: 3, entry: "hvc1", children: [hvcC(lengthSizeMinusOne: 3)]))
        #expect(isUnsupportedInit { try DolbyVision7InitRewriter.rewrite(Data(input), target: target) })
    }

    // MARK: - Helpers

    private func isUnsupportedInit(_ body: () throws -> Any) -> Bool {
        do {
            _ = try body()
            return false
        } catch DolbyVision7ConversionError.unsupportedInitSegment {
            return true
        } catch {
            return false
        }
    }

    /// HEVCDecoderConfigurationRecord with byte 21 = constantFrameRate 0,
    /// numTemporalLayers 1, temporalIdNested 1, lengthSizeMinusOne.
    private func hvcC(lengthSizeMinusOne: UInt8) -> [UInt8] {
        var record: [UInt8] = [1, 0x02, 0x20, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 153, 0xF0, 0, 0xFC, 0xFD, 0xFA, 0xFA, 0, 0]
        record += [0x0C | lengthSizeMinusOne, 0]
        return box("hvcC", record)
    }

    private func colr() -> [UInt8] {
        box("colr", Array("nclx".utf8) + [0, 9, 0, 16, 0, 9, 0x80])
    }

    /// Profile 7 level 6, rpu + el + bl, compatibility ID 6.
    private func profile7DvcC() -> [UInt8] {
        box("dvcC", [1, 0, 0x0E, 0x37, 0x60] + [UInt8](repeating: 0, count: 19))
    }

    private func videoTrak(
        trackID: UInt32,
        trackHeaderVersion: UInt8 = 0,
        entry: String,
        children: [[UInt8]]
    ) -> [UInt8] {
        let times = [UInt8](repeating: 0, count: trackHeaderVersion == 1 ? 16 : 8)
        let tkhd = fullBox("tkhd", version: trackHeaderVersion, flags: 3, times + u32(trackID) + [UInt8](repeating: 0, count: 68))
        let fields = (0..<78).map { UInt8($0) }
        let sampleEntry = box(entry, fields + children.flatMap { $0 })
        let stbl = box("stbl", fullBox("stsd", flags: 0, u32(1) + sampleEntry)
            + fullBox("stts", flags: 0, u32(0)) + fullBox("stsc", flags: 0, u32(0))
            + fullBox("stsz", flags: 0, u32(0) + u32(0)) + fullBox("stco", flags: 0, u32(0)))
        let minf = box("minf", fullBox("vmhd", flags: 1, [UInt8](repeating: 0, count: 8)) + stbl)
        let hdlr = fullBox("hdlr", flags: 0, u32(0) + Array("vide".utf8) + [UInt8](repeating: 0, count: 12) + Array("VideoHandler\0".utf8))
        let mdia = box("mdia", fullBox("mdhd", flags: 0, [UInt8](repeating: 0, count: 20)) + hdlr + minf)
        return box("trak", tkhd + mdia)
    }

    private func audioTrak() -> [UInt8] {
        let tkhd = fullBox("tkhd", flags: 3, [UInt8](repeating: 0, count: 8) + u32(2) + [UInt8](repeating: 0, count: 68))
        let entry = box("ec-3", [UInt8](repeating: 0, count: 6) + [0, 1] + [UInt8](repeating: 0, count: 20) + box("dec3", [0x0C, 0x00, 0x20, 0x0F, 0x00]))
        let stbl = box("stbl", fullBox("stsd", flags: 0, u32(1) + entry))
        let minf = box("minf", fullBox("smhd", flags: 0, [0, 0, 0, 0]) + stbl)
        let hdlr = fullBox("hdlr", flags: 0, u32(0) + Array("soun".utf8) + [UInt8](repeating: 0, count: 12) + Array("SoundHandler\0".utf8))
        return box("trak", tkhd + box("mdia", fullBox("mdhd", flags: 0, [UInt8](repeating: 0, count: 20)) + hdlr + minf))
    }

    /// ftyp + moov(mvhd, video trak, audio trak, mvex) as Plex's muxer
    /// writes a remux init segment.
    private func initSegment(
        brands: [String] = ["isom", "iso6", "mp41"],
        videoEntry: String = "hvc1",
        videoChildren: [[UInt8]]? = nil,
        videoTrackHeaderVersion: UInt8 = 0,
        videoTrackID: UInt32 = 1,
        extraTrak: [UInt8] = []
    ) -> [UInt8] {
        let children = videoChildren ?? [hvcC(lengthSizeMinusOne: 3), profile7DvcC(), colr()]
        let ftyp = box("ftyp", Array("isom".utf8) + u32(0x200) + brands.flatMap { Array($0.utf8) })
        let trex1 = fullBox("trex", flags: 0, u32(videoTrackID) + u32(1) + u32(1001) + u32(0) + u32(0x0001_0000))
        let trex2 = fullBox("trex", flags: 0, u32(2) + u32(1) + u32(1536) + u32(0) + u32(0x0200_0000))
        let moov = box("moov",
            fullBox("mvhd", flags: 0, [UInt8](repeating: 0, count: 96))
            + videoTrak(trackID: videoTrackID, trackHeaderVersion: videoTrackHeaderVersion, entry: videoEntry, children: children)
            + audioTrak()
            + extraTrak
            + box("mvex", trex1 + trex2))
        return ftyp + moov
    }
}

@Suite("Dolby Vision 7 media segment rewrite")
struct DolbyVision7FragmentRewriterTests {
    private let info = FMP4InitInfo(
        video: FMP4VideoTrackInfo(trackID: 1, nalLengthSize: 4),
        trexDefaults: [:]
    )

    /// slice NAL + EL NAL (type 63) + RPU NAL (type 62): 7 + 8 + 9 bytes.
    private let rpuSample = nal([0x02, 0x01, 0xAA]) + nal([0x7E, 0x01, 0xE1, 0xE2]) + nal([0x7C, 0x01, 0x19, 0x08, 0x09])
    /// The slice NAL + the fake converted RPU: 7 + 14 bytes.
    private let convertedSample = nal([0x02, 0x01, 0xAA]) + nal(FakeSampleRewriter.convertedRPU)
    private let plainSample = nal([0x02, 0x01, 0xBB])
    private let audioA: [UInt8] = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4]
    private let audioB: [UInt8] = [0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5]

    // MARK: Sizes in the trun

    /// mfhd 16 + traf(tfhd 16 + tfdt 20 + trun v1 0xB01 with 2 × 12-byte
    /// entries 44 = 88) → moof 112; data_offset = 112 + 8-byte mdat header.
    private func sizedFragment(sizes: [UInt32], dataOffset: Int32) -> [UInt8] {
        moof(sequence: 1, trafs: [
            fullBox("tfhd", flags: 0x02_0000, u32(1)) + tfdt()
                + trun(version: 1, flags: 0xB01, dataOffset: dataOffset, entries: [
                    u32(1001) + u32(sizes[0]) + i32(-1001),
                    u32(1001) + u32(sizes[1]) + i32(2002),
                ]),
        ])
    }

    @Test func sizesAndDataOffsetWithDefaultBaseIsMoof() throws {
        let input = sizedFragment(sizes: [24, 7], dataOffset: 120) + box("mdat", rpuSample + plainSample)
        #expect(input.count == 112 + 8 + 31)
        let (data, stats) = try rewrite(input)

        let expected = sizedFragment(sizes: [21, 7], dataOffset: 120) + box("mdat", convertedSample + plainSample)
        #expect([UInt8](data) == expected)
        #expect(stats.sampleCount == 2)
        #expect(stats.nalCount == 4)
        #expect(stats.rpuCount == 1)
        #expect(stats.enhancementLayerNALCount == 1)
        #expect(stats.inputBytes == 31)
        #expect(stats.outputBytes == 28)
    }

    @Test func largesizeAndSizeZeroMdatInputs() throws {
        let payload = rpuSample + plainSample
        let largesize = sizedFragment(sizes: [24, 7], dataOffset: 112 + 16)
            + u32(1) + Array("mdat".utf8) + u64(UInt64(16 + payload.count)) + payload
        let toEnd = sizedFragment(sizes: [24, 7], dataOffset: 120) + u32(0) + Array("mdat".utf8) + payload

        let expected = sizedFragment(sizes: [21, 7], dataOffset: 120) + box("mdat", convertedSample + plainSample)
        #expect(try [UInt8](rewrite(largesize).data) == expected)
        #expect(try [UInt8](rewrite(toEnd).data) == expected)
    }

    // MARK: Default sizes

    @Test func tfhdDefaultSizeGrowsTheTrun() throws {
        // tfhd 20 (default size 24) + tfdt 20 + trun 0x001 20 → traf 68,
        // moof 92, data_offset 100.
        let input = moof(sequence: 1, trafs: [
            fullBox("tfhd", flags: 0x02_0010, u32(1) + u32(24)) + tfdt()
                + trun(flags: 0x001, sampleCount: 2, dataOffset: 100, entries: []),
        ]) + box("mdat", rpuSample + rpuSample)
        #expect(input.count == 92 + 8 + 48)
        let (data, _) = try rewrite(input)

        // The trun gains two sizes (+8): traf 76, moof 100, data_offset 108.
        let expectedTrun: [UInt8] = [0, 0, 0, 28] + Array("trun".utf8)
            + [0, 0, 0x02, 0x01] + [0, 0, 0, 2] + [0, 0, 0, 108] + [0, 0, 0, 21] + [0, 0, 0, 21]
        let expected = moof(sequence: 1, trafs: [
            fullBox("tfhd", flags: 0x02_0010, u32(1) + u32(24)) + tfdt() + expectedTrun,
        ]) + box("mdat", convertedSample + convertedSample)
        #expect([UInt8](data) == expected)
    }

    @Test func trexDefaultSize() throws {
        let input = moof(sequence: 1, trafs: [
            fullBox("tfhd", flags: 0x02_0000, u32(1)) + tfdt()
                + trun(flags: 0x001, sampleCount: 2, dataOffset: 96, entries: []),
        ]) + box("mdat", rpuSample + rpuSample)
        let trexInfo = FMP4InitInfo(
            video: info.video,
            trexDefaults: [1: FMP4TrackDefaults(defaultSampleDuration: 1001, defaultSampleSize: 24, defaultSampleFlags: 0)]
        )
        let (data, _) = try FMP4FragmentRewriter(info: trexInfo, sampleRewriter: FakeSampleRewriter()).rewrite(Data(input))

        // tfhd 16 + tfdt 20 + trun 28 → traf 72, moof 96, data_offset 104.
        let expected = moof(sequence: 1, trafs: [
            fullBox("tfhd", flags: 0x02_0000, u32(1)) + tfdt()
                + trun(flags: 0x201, dataOffset: 104, entries: [u32(21), u32(21)]),
        ]) + box("mdat", convertedSample + convertedSample)
        #expect([UInt8](data) == expected)

        // Without the trex default there is no size at all.
        #expect(isUnsupportedFragment { try rewrite(input) })
    }

    // MARK: Several tracks, runs and fragments

    /// mfhd 16 + video traf (16 + 20 + 28 = 72) + audio traf 72 → moof 168.
    private func avFragment(videoSizes: [UInt32], videoOffset: Int32, audioOffset: Int32) -> [UInt8] {
        moof(sequence: 1, trafs: [
            fullBox("tfhd", flags: 0x02_0000, u32(1)) + tfdt()
                + trun(flags: 0x201, dataOffset: videoOffset, entries: videoSizes.map(u32)),
            fullBox("tfhd", flags: 0x02_0000, u32(2)) + tfdt()
                + trun(flags: 0x201, dataOffset: audioOffset, entries: [u32(5), u32(6)]),
        ])
    }

    @Test func audioBytesAreCopiedAndItsDataOffsetShifts() throws {
        let videoFirst = avFragment(videoSizes: [24, 7], videoOffset: 176, audioOffset: 176 + 31)
            + box("mdat", rpuSample + plainSample + audioA + audioB)
        // Same samples with the audio first in the mdat: the output follows
        // traf order.
        let audioFirst = avFragment(videoSizes: [24, 7], videoOffset: 176 + 11, audioOffset: 176)
            + box("mdat", audioA + audioB + rpuSample + plainSample)

        // Video shrinks by 3 bytes, so audio moves from 207 to 204.
        let expected = avFragment(videoSizes: [21, 7], videoOffset: 176, audioOffset: 204)
            + box("mdat", convertedSample + plainSample + audioA + audioB)
        #expect(try [UInt8](rewrite(videoFirst).data) == expected)
        #expect(try [UInt8](rewrite(audioFirst).data) == expected)
    }

    @Test func baseDataOffsetBecomesDefaultBaseIsMoof() throws {
        let styp = box("styp", Array("msdh".utf8) + u32(0) + Array("msdh".utf8) + Array("msix".utf8))
        // styp 24; tfhd 24 (base_data_offset) + tfdt 20 + trun 0x200 24 →
        // traf 76, moof 100 at 24, so the mdat payload starts at 132.
        let input = styp + moof(sequence: 1, trafs: [
            fullBox("tfhd", flags: 0x00_0001, u32(1) + u64(132)) + tfdt()
                + trun(flags: 0x200, dataOffset: nil, entries: [u32(24), u32(7)]),
        ]) + box("mdat", rpuSample + plainSample)
        #expect(input.count == 132 + 31)
        let (data, _) = try rewrite(input)

        // tfhd 16 + tfdt 20 + trun 28 → traf 72, moof 96, data_offset 104.
        let expected = styp + moof(sequence: 1, trafs: [
            fullBox("tfhd", flags: 0x02_0000, u32(1)) + tfdt()
                + trun(flags: 0x201, dataOffset: 104, entries: [u32(21), u32(7)]),
        ]) + box("mdat", convertedSample + plainSample)
        #expect([UInt8](data) == expected)
    }

    @Test func runWithoutDataOffsetFollowsThePreviousRun() throws {
        // tfhd 16 + tfdt 20 + trun 24 + trun 20 → traf 88, moof 112.
        let input = moof(sequence: 1, trafs: [
            fullBox("tfhd", flags: 0x02_0000, u32(1)) + tfdt()
                + trun(flags: 0x201, dataOffset: 120, entries: [u32(24)])
                + trun(flags: 0x200, dataOffset: nil, entries: [u32(7)]),
        ]) + box("mdat", rpuSample + plainSample)
        let (data, _) = try rewrite(input)

        // The second trun gains data_offset (+4): moof 116.
        let expected = moof(sequence: 1, trafs: [
            fullBox("tfhd", flags: 0x02_0000, u32(1)) + tfdt()
                + trun(flags: 0x201, dataOffset: 124, entries: [u32(21)])
                + trun(flags: 0x201, dataOffset: 124 + 21, entries: [u32(7)]),
        ]) + box("mdat", convertedSample + plainSample)
        #expect([UInt8](data) == expected)
    }

    @Test func twoFragmentsKeepStypAndDropSidx() throws {
        let styp = box("styp", Array("msdh".utf8) + u32(0) + Array("msdh".utf8))
        let sidx = fullBox("sidx", version: 1, flags: 0, u32(1) + u32(90000) + u64(0) + u64(0) + u32(1) + u32(155) + u32(540_540) + u32(0x9000_0000))
        // tfhd 16 + tfdt 20 + trun 24 → traf 68, moof 92, data_offset 100.
        func pair(_ sequence: UInt32, size: UInt32, sample: [UInt8]) -> [UInt8] {
            moof(sequence: sequence, trafs: [
                fullBox("tfhd", flags: 0x02_0000, u32(1)) + tfdt()
                    + trun(flags: 0x201, dataOffset: 100, entries: [u32(size)]),
            ]) + box("mdat", sample)
        }
        let input = styp + sidx + pair(1, size: 24, sample: rpuSample) + pair(2, size: 24, sample: rpuSample)
        let (data, stats) = try rewrite(input)

        let expected = styp + pair(1, size: 21, sample: convertedSample) + pair(2, size: 21, sample: convertedSample)
        #expect([UInt8](data) == expected)
        #expect(stats.sampleCount == 2)
        #expect(stats.rpuCount == 2)
    }

    // MARK: Rejected input

    @Test func sencInVideoTrafThrows() {
        // traf 8 + 16 + 20 + 24 + senc 16 = 84, moof 108: the run itself is
        // valid.
        let input = moof(sequence: 1, trafs: [
            fullBox("tfhd", flags: 0x02_0000, u32(1)) + tfdt()
                + trun(flags: 0x201, dataOffset: 116, entries: [u32(24)])
                + fullBox("senc", flags: 0, u32(0)),
        ]) + box("mdat", rpuSample)
        #expect(isUnsupportedFragment { try rewrite(input) })
    }

    @Test func sampleOutsideTheMdatThrows() throws {
        // moof 92 → payload at 100..<124; start one byte late, then a size
        // one byte too large.
        func fragment(dataOffset: Int32, size: UInt32) -> [UInt8] {
            moof(sequence: 1, trafs: [
                fullBox("tfhd", flags: 0x02_0000, u32(1)) + tfdt()
                    + trun(flags: 0x201, dataOffset: dataOffset, entries: [u32(size)]),
            ]) + box("mdat", rpuSample)
        }
        #expect(try [UInt8](rewrite(fragment(dataOffset: 100, size: 24)).data).count == 92 + 8 + 21)
        #expect(isUnsupportedFragment { try rewrite(fragment(dataOffset: 101, size: 24)) })
        #expect(isUnsupportedFragment { try rewrite(fragment(dataOffset: 100, size: 25)) })
        #expect(isUnsupportedFragment { try rewrite(fragment(dataOffset: 0, size: 24)) })
    }

    @Test func moofWithoutMdatThrows() {
        let input = moof(sequence: 1, trafs: [
            fullBox("tfhd", flags: 0x02_0000, u32(1)) + tfdt() + trun(flags: 0x201, dataOffset: 0, entries: [u32(24)]),
        ])
        #expect(isUnsupportedFragment { try rewrite(input) })
    }

    /// tfhd default_sample_size 0 makes every sample empty and a `trun`
    /// without entries 20 bytes, so only fragment-wide budgets keep many
    /// runs from describing far more samples than the mdat could hold.
    @Test func sampleCountIsBudgetedAcrossRuns() throws {
        func zeroSizeRuns(_ counts: [Int], dataOffset: Int32) -> [UInt8] {
            moof(sequence: 1, trafs: [
                fullBox("tfhd", flags: 0x02_0010, u32(1) + u32(0)) + tfdt()
                    + counts.flatMap { trun(flags: 0x001, sampleCount: $0, dataOffset: dataOffset, entries: []) },
            ]) + box("mdat", [0, 0, 0, 0])
        }
        // tfhd 20 + tfdt 20 + trun 20 → traf 68, moof 92: payload at 100.
        _ = try rewrite(zeroSizeRuns([3], dataOffset: 100))
        // Two runs → traf 88, moof 112: 3 + 3 samples for a 4-byte mdat.
        #expect(isUnsupportedFragment { try rewrite(zeroSizeRuns([3, 3], dataOffset: 120)) })
    }

    @Test func sampleCountHasAnAbsoluteCeiling() {
        let count = FMP4FragmentRewriter.maximumSamplesPerFragment + 1
        let input = moof(sequence: 1, trafs: [
            fullBox("tfhd", flags: 0x02_0010, u32(1) + u32(0)) + tfdt()
                + trun(flags: 0x001, sampleCount: count, dataOffset: 100, entries: []),
        ]) + box("mdat", [UInt8](repeating: 0, count: count))
        #expect(isUnsupportedFragment { try rewrite(input) })
    }

    @Test func runsSharingBytesThrow() {
        // tfhd 16 + tfdt 20 + 2 × trun 24 → traf 92, moof 116: payload at
        // 124. Both runs claim the same sample.
        let input = moof(sequence: 1, trafs: [
            fullBox("tfhd", flags: 0x02_0000, u32(1)) + tfdt()
                + trun(flags: 0x201, dataOffset: 124, entries: [u32(24)])
                + trun(flags: 0x201, dataOffset: 124, entries: [u32(24)]),
        ]) + box("mdat", rpuSample)
        #expect(isUnsupportedFragment { try rewrite(input) })
    }

    @Test func cancellationStopsBetweenSamples() async {
        let sampleRewriter = CancellingSampleRewriter()
        let rewriter = FMP4FragmentRewriter(info: info, sampleRewriter: sampleRewriter)
        let input = Data(sizedFragment(sizes: [24, 7], dataOffset: 120) + box("mdat", rpuSample + plainSample))

        let result = await Task { try rewriter.rewrite(input) }.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(sampleRewriter.calls == 1)
    }

    // MARK: - Helpers

    private func rewrite(_ bytes: [UInt8]) throws -> (data: Data, stats: DolbyVisionSampleStats) {
        try FMP4FragmentRewriter(info: info, sampleRewriter: FakeSampleRewriter()).rewrite(Data(bytes))
    }

    private func isUnsupportedFragment(_ body: () throws -> Any) -> Bool {
        do {
            _ = try body()
            return false
        } catch DolbyVision7ConversionError.unsupportedFragment {
            return true
        } catch {
            return false
        }
    }

    private func moof(sequence: UInt32, trafs: [[UInt8]]) -> [UInt8] {
        box("moof", fullBox("mfhd", flags: 0, u32(sequence)) + trafs.flatMap { box("traf", $0) })
    }

    private func tfdt() -> [UInt8] {
        fullBox("tfdt", version: 1, flags: 0, u64(900_000))
    }

    private func trun(
        version: UInt8 = 0,
        flags: UInt32,
        sampleCount: Int? = nil,
        dataOffset: Int32?,
        entries: [[UInt8]]
    ) -> [UInt8] {
        fullBox("trun", version: version, flags: flags,
                u32(UInt32(sampleCount ?? entries.count)) + (dataOffset.map(i32) ?? []) + entries.flatMap { $0 })
    }
}

/// The fragment rewriter and the real DuskDovi bridge together: a FEL
/// sample from dovi_tool's test vectors loses its enhancement layer and its
/// RPU comes out as the mode 2 golden, inside a correctly resized fragment.
@Suite("Dolby Vision 7 fragment rewrite through DuskDovi")
struct DolbyVision7EndToEndTests {
    private let info = FMP4InitInfo(
        video: FMP4VideoTrackInfo(trackID: 1, nalLengthSize: 4),
        trexDefaults: [:]
    )
    private let slice: [UInt8] = [0x02, 0x01, 0xD0, 0x11, 0x22, 0x33]
    private let enhancementLayer: [UInt8] = [0x7E, 0x01, 0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF]
    private let audio: [UInt8] = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6]

    /// mfhd 16 + two trafs of tfhd 16 + tfdt 20 + trun 0x201 (one entry) 24
    /// = 68 each → moof 160; the first run starts at 160 + 8.
    private func fragment(videoSample: [UInt8]) -> [UInt8] {
        func traf(trackID: UInt32, size: Int, dataOffset: Int) -> [UInt8] {
            box("traf",
                fullBox("tfhd", flags: 0x02_0000, u32(trackID))
                    + fullBox("tfdt", version: 1, flags: 0, u64(900_000))
                    + fullBox("trun", flags: 0x201, u32(1) + i32(Int32(dataOffset)) + u32(UInt32(size))))
        }
        let moof = box("moof",
            fullBox("mfhd", flags: 0, u32(7))
                + traf(trackID: 1, size: videoSample.count, dataOffset: 168)
                + traf(trackID: 2, size: audio.count, dataOffset: 168 + videoSample.count))
        return moof + box("mdat", videoSample + audio)
    }

    @Test func felSampleDropsTheEnhancementLayerAndConvertsTheRPU() throws {
        let rpu = [UInt8](DolbyVision7Fixtures.rpuNAL(DolbyVision7Fixtures.felOriginal))
        let convertedRPU = [UInt8](DolbyVision7Fixtures.rpuNAL(DolbyVision7Fixtures.felConverted))
        let sample = nal(slice) + nal(enhancementLayer) + nal(rpu)
        let expectedSample = nal(slice) + nal(convertedRPU)

        let input = fragment(videoSample: sample)
        #expect(input.count == 160 + 8 + sample.count + audio.count)

        let (data, stats) = try FMP4FragmentRewriter(info: info, sampleRewriter: DoviBridgeSampleRewriter())
            .rewrite(Data(input))

        // Same layout with the new video size; the audio run's data_offset
        // follows the shorter video sample.
        #expect([UInt8](data) == fragment(videoSample: expectedSample))
        #expect(stats == DolbyVisionSampleStats(
            sampleCount: 1,
            nalCount: 3,
            rpuCount: 1,
            enhancementLayerNALCount: 1,
            sourceProfile: 7,
            sourceELType: .fel,
            inputBytes: sample.count,
            outputBytes: expectedSample.count
        ))
    }
}

/// Stands in for the libdovi bridge: drops enhancement-layer NAL units
/// (type 63), replaces each RPU (type 62) with `convertedRPU`, copies the
/// rest.
struct FakeSampleRewriter: DolbyVisionSampleRewriting {
    static let convertedRPU: [UInt8] = [0x7C, 0x01, 0x19, 0x08, 0x81, 0xC0, 0xFF, 0xEE, 0x12, 0x80]

    func rewriteSample(
        _ sample: UnsafeRawBufferPointer,
        nalLengthSize: Int,
        appendingTo output: inout Data
    ) throws -> DolbyVisionSampleStats {
        let bytes = [UInt8](sample)
        var stats = DolbyVisionSampleStats()
        var offset = 0
        while offset < bytes.count {
            guard offset + nalLengthSize <= bytes.count else { throw DolbyVision7ConversionError.malformedSample }
            let length = bytes[offset..<(offset + nalLengthSize)].reduce(0) { $0 << 8 | Int($1) }
            let nalStart = offset + nalLengthSize
            guard length >= 2, nalStart + length <= bytes.count else { throw DolbyVision7ConversionError.malformedSample }
            stats.nalCount += 1
            switch (bytes[nalStart] >> 1) & 0x3F {
            case 63:
                stats.enhancementLayerNALCount += 1
            case 62:
                stats.rpuCount += 1
                stats.sourceProfile = 7
                stats.sourceELType = .fel
                output.append(contentsOf: lengthPrefix(Self.convertedRPU.count, size: nalLengthSize) + Self.convertedRPU)
            default:
                output.append(contentsOf: bytes[offset..<(nalStart + length)])
            }
            offset = nalStart + length
        }
        return stats
    }

    private func lengthPrefix(_ length: Int, size: Int) -> [UInt8] {
        (0..<size).reversed().map { UInt8((length >> ($0 * 8)) & 0xFF) }
    }
}

/// Cancels the task it runs on while rewriting the first sample, the way a
/// seek abandons a segment mid-conversion.
private final class CancellingSampleRewriter: DolbyVisionSampleRewriting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.withLock { count } }

    func rewriteSample(
        _ sample: UnsafeRawBufferPointer,
        nalLengthSize: Int,
        appendingTo output: inout Data
    ) throws -> DolbyVisionSampleStats {
        lock.withLock { count += 1 }
        withUnsafeCurrentTask { $0?.cancel() }
        output.append(contentsOf: sample)
        return DolbyVisionSampleStats()
    }
}

// MARK: - Box builders

private func u32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

private func i32(_ value: Int32) -> [UInt8] {
    u32(UInt32(bitPattern: value))
}

private func u64(_ value: UInt64) -> [UInt8] {
    u32(UInt32(value >> 32)) + u32(UInt32(value & 0xFFFF_FFFF))
}

private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    u32(UInt32(8 + payload.count)) + Array(type.utf8) + payload
}

private func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32, _ payload: [UInt8]) -> [UInt8] {
    box(type, [version] + Array(u32(flags).dropFirst()) + payload)
}

/// A NAL unit with a 4-byte length prefix.
private func nal(_ unit: [UInt8]) -> [UInt8] {
    u32(UInt32(unit.count)) + unit
}
