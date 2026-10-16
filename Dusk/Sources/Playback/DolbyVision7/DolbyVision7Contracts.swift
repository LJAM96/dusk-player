import Foundation

/// Enhancement-layer type of a Dolby Vision profile 7 source RPU.
enum DolbyVisionELType: UInt8, Sendable { case none = 0, mel = 1, fel = 2 }

/// What converting one sample (or, merged, a whole segment) did.
struct DolbyVisionSampleStats: Sendable, Equatable {
    var sampleCount = 0
    var nalCount = 0
    var rpuCount = 0
    var enhancementLayerNALCount = 0
    var sourceProfile: Int? = nil
    var sourceELType: DolbyVisionELType? = nil
    var inputBytes = 0
    var outputBytes = 0

    mutating func merge(_ other: DolbyVisionSampleStats) {
        sampleCount += other.sampleCount
        nalCount += other.nalCount
        rpuCount += other.rpuCount
        enhancementLayerNALCount += other.enhancementLayerNALCount
        sourceProfile = other.sourceProfile ?? sourceProfile
        sourceELType = other.sourceELType ?? sourceELType
        inputBytes += other.inputBytes
        outputBytes += other.outputBytes
    }
}

enum DolbyVision7ConversionError: Error, Sendable, Equatable {
    case invalidArgument
    case malformedSample
    case rpuParse
    case rpuConvert
    case rpuWrite
    case bridgePanic
    case unsupportedInitSegment(String)
    case unsupportedFragment(String)
    case unsupportedPlaylist(String)
    case missingRPU
    case proxyUnavailable(String)
}

/// Rewrites one length-prefixed HEVC sample of a Dolby Vision profile 7
/// stream as profile 8.1. Throws `DolbyVision7ConversionError`.
protocol DolbyVisionSampleRewriting: Sendable {
    func rewriteSample(
        _ sample: UnsafeRawBufferPointer,
        nalLengthSize: Int,
        appendingTo output: inout Data
    ) throws -> DolbyVisionSampleStats
}
