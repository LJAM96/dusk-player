import Foundation
import Testing
@testable import Dusk

@Suite("DuskDovi bridge")
struct DoviBridgeTests {
    private static let sliceNAL = Data([0x02, 0x01, 0xD0, 0x11, 0x22, 0x33, 0x44])
    private static let enhancementLayerNAL = Data([0x7E, 0x01, 0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF])

    @Test func abiVersionMatchesHeader() {
        #expect(DoviBridge.abiVersion == 1)
    }

    @Test func melRPUConvertsToGolden() throws {
        let (nal, profile, elType) = try DoviBridge.convertRPUNAL(
            DolbyVision7Fixtures.rpuNAL(DolbyVision7Fixtures.melOriginal))
        #expect(nal == DolbyVision7Fixtures.rpuNAL(DolbyVision7Fixtures.melConverted))
        #expect(profile == 7)
        #expect(elType == .mel)
    }

    @Test func felRPUConvertsToGolden() throws {
        let (nal, profile, elType) = try DoviBridge.convertRPUNAL(
            DolbyVision7Fixtures.rpuNAL(DolbyVision7Fixtures.felOriginal))
        #expect(nal == DolbyVision7Fixtures.rpuNAL(DolbyVision7Fixtures.felConverted))
        #expect(profile == 7)
        #expect(elType == .fel)
    }

    @Test func garbageRPUThrowsParseError() {
        #expect(throws: DolbyVision7ConversionError.rpuParse) {
            try DoviBridge.convertRPUNAL(Data([0x7C, 0x01, 0x19, 0x08, 0x09, 0x00, 0x01]))
        }
        #expect(throws: DolbyVision7ConversionError.invalidArgument) {
            try DoviBridge.convertRPUNAL(Data())
        }
    }

    @Test(arguments: [2, 4])
    func sampleDropsEnhancementLayerAndConvertsRPU(nalLengthSize: Int) throws {
        let rpu = DolbyVision7Fixtures.rpuNAL(DolbyVision7Fixtures.felOriginal)
        let sample = Self.lengthPrefixed([Self.sliceNAL, Self.enhancementLayerNAL, rpu], size: nalLengthSize)
        let expected = Self.lengthPrefixed(
            [Self.sliceNAL, DolbyVision7Fixtures.rpuNAL(DolbyVision7Fixtures.felConverted)],
            size: nalLengthSize)

        // Existing bytes in the output stay untouched; the sample is appended.
        let prefix = Data([0xAB, 0xCD])
        var output = prefix
        let stats = try Self.rewrite(sample, nalLengthSize: nalLengthSize, into: &output)

        #expect(output == prefix + expected)
        #expect(stats == DolbyVisionSampleStats(
            sampleCount: 1,
            nalCount: 3,
            rpuCount: 1,
            enhancementLayerNALCount: 1,
            sourceProfile: 7,
            sourceELType: .fel,
            inputBytes: sample.count,
            outputBytes: expected.count
        ))
    }

    @Test func sampleWithoutDolbyVisionIsCopied() throws {
        let sample = Self.lengthPrefixed([Self.sliceNAL, Self.sliceNAL], size: 4)
        var output = Data()
        let stats = try Self.rewrite(sample, nalLengthSize: 4, into: &output)
        #expect(output == sample)
        #expect(stats.nalCount == 2)
        #expect(stats.rpuCount == 0)
        #expect(stats.sourceProfile == nil)
        #expect(stats.sourceELType == nil)
    }

    @Test func emptySampleCountsAsOneSample() throws {
        var output = Data([0x01])
        let stats = try Self.rewrite(Data(), nalLengthSize: 4, into: &output)
        #expect(output == Data([0x01]))
        #expect(stats == DolbyVisionSampleStats(sampleCount: 1))
    }

    @Test func malformedSampleThrowsAndLeavesOutputUnchanged() {
        var sample = Self.lengthPrefixed([Self.sliceNAL], size: 4)
        sample.removeLast()
        var output = Data([0x01, 0x02])
        #expect(throws: DolbyVision7ConversionError.malformedSample) {
            try Self.rewrite(sample, nalLengthSize: 4, into: &output)
        }
        #expect(output == Data([0x01, 0x02]))
    }

    @Test func invalidLengthSizeThrows() {
        var output = Data()
        #expect(throws: DolbyVision7ConversionError.invalidArgument) {
            try Self.rewrite(Self.lengthPrefixed([Self.sliceNAL], size: 4), nalLengthSize: 5, into: &output)
        }
    }

    @Test func mergedStatsKeepLastSourceProfile() throws {
        let rpuSample = Self.lengthPrefixed(
            [Self.sliceNAL, DolbyVision7Fixtures.rpuNAL(DolbyVision7Fixtures.melOriginal)], size: 4)
        let plainSample = Self.lengthPrefixed([Self.sliceNAL], size: 4)
        var output = Data()
        var total = DolbyVisionSampleStats()
        total.merge(try Self.rewrite(rpuSample, nalLengthSize: 4, into: &output))
        total.merge(try Self.rewrite(plainSample, nalLengthSize: 4, into: &output))
        #expect(total.sampleCount == 2)
        #expect(total.rpuCount == 1)
        #expect(total.sourceProfile == 7)
        #expect(total.sourceELType == .mel)
        #expect(total.outputBytes == output.count)
    }

    private static func rewrite(
        _ sample: Data,
        nalLengthSize: Int,
        into output: inout Data
    ) throws -> DolbyVisionSampleStats {
        try sample.withUnsafeBytes { buffer in
            try DoviBridgeSampleRewriter().rewriteSample(buffer, nalLengthSize: nalLengthSize, appendingTo: &output)
        }
    }

    private static func lengthPrefixed(_ nals: [Data], size: Int) -> Data {
        var sample = Data()
        for nal in nals {
            for shift in stride(from: (size - 1) * 8, through: 0, by: -8) {
                sample.append(UInt8(truncatingIfNeeded: nal.count >> shift))
            }
            sample.append(nal)
        }
        return sample
    }
}
