import DuskDovi
import Foundation

/// Swift face of DuskDovi (`Native/DuskDovi`, Rust over quietvoid's
/// dolby_vision crate). The only file that imports the C module.
enum DoviBridge {
    static var abiVersion: UInt32 { dusk_dovi_abi_version() }

    /// Converts one HEVC UNSPEC62 RPU NAL unit (header `7C 01` first) to
    /// profile 8.1 (dovi_tool mode 2). Returns the converted NAL with its
    /// header, the source profile and the source enhancement-layer type.
    static func convertRPUNAL(_ nal: Data) throws -> (Data, Int, DolbyVisionELType) {
        var capacity = nal.count + 1024
        while true {
            var output = Data(count: capacity)
            var written = 0
            var profile: UInt8 = 0
            var elType: UInt8 = 0
            let status = nal.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { buffer in
                    dusk_dovi_convert_rpu_nal_to_81(
                        input.baseAddress?.assumingMemoryBound(to: UInt8.self), input.count,
                        buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), capacity,
                        &written, &profile, &elType
                    )
                }
            }
            if status == DUSK_DOVI_ERR_OUTPUT_TOO_SMALL, written > capacity {
                capacity = written
                continue
            }
            guard status == DUSK_DOVI_OK else { throw conversionError(status) }
            output.count = written
            return (output, Int(profile), DolbyVisionELType(rawValue: elType) ?? .none)
        }
    }

    static func conversionError(_ status: Int32) -> DolbyVision7ConversionError {
        switch status {
        case DUSK_DOVI_ERR_MALFORMED_SAMPLE: .malformedSample
        case DUSK_DOVI_ERR_RPU_PARSE: .rpuParse
        case DUSK_DOVI_ERR_RPU_CONVERT: .rpuConvert
        case DUSK_DOVI_ERR_RPU_WRITE: .rpuWrite
        case DUSK_DOVI_ERR_PANIC: .bridgePanic
        default: .invalidArgument
        }
    }
}

/// Drops enhancement-layer NAL units and converts RPUs to 8.1 through DuskDovi.
struct DoviBridgeSampleRewriter: DolbyVisionSampleRewriting {
    func rewriteSample(
        _ sample: UnsafeRawBufferPointer,
        nalLengthSize: Int,
        appendingTo output: inout Data
    ) throws -> DolbyVisionSampleStats {
        guard (1...4).contains(nalLengthSize) else { throw DolbyVision7ConversionError.invalidArgument }
        guard let samplePointer = sample.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return DolbyVisionSampleStats(sampleCount: 1)
        }

        let start = output.count
        // Converted RPUs are usually smaller than the source; the slack covers
        // the rest, so the retry below is a safety net.
        var capacity = sample.count + 1024
        var written = 0
        var stats = DuskDoviSampleStats()
        while true {
            output.count = start + capacity
            let status = output.withUnsafeMutableBytes { buffer in
                dusk_dovi_rewrite_sample_to_81(
                    samplePointer, sample.count, UInt8(nalLengthSize),
                    buffer.baseAddress?.advanced(by: start).assumingMemoryBound(to: UInt8.self), capacity,
                    &written, &stats
                )
            }
            if status == DUSK_DOVI_ERR_OUTPUT_TOO_SMALL, written > capacity {
                capacity = written
                continue
            }
            guard status == DUSK_DOVI_OK else {
                output.count = start
                throw DoviBridge.conversionError(status)
            }
            output.count = start + written
            break
        }

        let hasRPU = stats.rpu_count > 0
        return DolbyVisionSampleStats(
            sampleCount: 1,
            nalCount: Int(stats.nal_count),
            rpuCount: Int(stats.rpu_count),
            enhancementLayerNALCount: Int(stats.el_nal_count),
            sourceProfile: hasRPU ? Int(stats.source_profile) : nil,
            sourceELType: hasRPU ? DolbyVisionELType(rawValue: stats.source_el_type) : nil,
            inputBytes: sample.count,
            outputBytes: written
        )
    }
}
