import Foundation

/// Converts the video samples of a Dolby Vision profile 7 fMP4 media
/// segment to profile 8.1 and rebuilds each `moof`/`mdat` pair around the
/// new sample sizes.
///
/// Sample positions follow ISO/IEC 14496-12 (8.8.7, 8.8.8): a run starts at
/// the track fragment's base plus its `data_offset`, or right after the
/// previous run. The base is `base_data_offset` (taken relative to the
/// segment, the only "file" a standalone HLS segment has), else the `moof`
/// start when `default-base-is-moof` is set or for the first `traf`, else
/// the end of the previous `traf`'s data.
///
/// The rebuilt pair always uses `default-base-is-moof` and an explicit
/// `data_offset` on every run, with each run's samples written contiguously
/// in `traf` → `trun` → sample order. Video runs gain per-sample sizes;
/// other tracks keep their entries and bytes unchanged. `sidx`/`ssix`
/// (byte ranges no longer valid) are dropped; other top-level boxes such as
/// `styp` and `emsg` are copied.
///
/// Throws `DolbyVision7ConversionError`, or `CancellationError` once the
/// calling task is cancelled (checked between samples).
struct FMP4FragmentRewriter: Sendable {
    private static let dataOffsetPresent: UInt32 = 0x1
    private static let firstSampleFlagsPresent: UInt32 = 0x4
    private static let sampleDurationPresent: UInt32 = 0x100
    private static let sampleSizePresent: UInt32 = 0x200
    private static let perSampleFields: UInt32 = 0xF00

    private static let baseDataOffsetPresent: UInt32 = 0x1
    private static let sampleDescriptionIndexPresent: UInt32 = 0x2
    private static let defaultSampleDurationPresent: UInt32 = 0x8
    private static let defaultSampleSizePresent: UInt32 = 0x10
    private static let defaultSampleFlagsPresent: UInt32 = 0x20
    private static let defaultBaseIsMoof: UInt32 = 0x20000

    /// Sample-level metadata that would no longer match a rewritten video
    /// sample (encryption, sub-sample sizes).
    private static let unsupportedVideoBoxes: Set<String> = ["senc", "saiz", "subs"]

    /// Samples one `moof` may describe across all its runs. A real Plex
    /// fragment holds a few hundred (≤ 10 s of video at ≤ 60 fps plus its
    /// audio frames); this leaves room for even per-frame PCM while keeping
    /// the parsed sizes and rebuilt `trun` entries to a few tens of MB.
    static let maximumSamplesPerFragment = 1 << 20

    let info: FMP4InitInfo
    let sampleRewriter: any DolbyVisionSampleRewriting

    init(info: FMP4InitInfo, sampleRewriter: any DolbyVisionSampleRewriting) {
        self.info = info
        self.sampleRewriter = sampleRewriter
    }

    func rewrite(_ segment: Data) throws -> (data: Data, stats: DolbyVisionSampleStats) {
        try segment.withUnsafeBytes { bytes in
            let topLevel = try FMP4Box.boxes(in: bytes, range: 0..<bytes.count, failure: Self.fail)
            var output = Data()
            // Room for added size fields and the bridge's per-sample output
            // slack, so a 10–20 MB segment is written without regrowing.
            output.reserveCapacity(bytes.count + 64 * 1024)
            var stats = DolbyVisionSampleStats()

            var index = 0
            while index < topLevel.count {
                let box = topLevel[index]
                switch box.type {
                case "sidx", "ssix":
                    break
                case "moof":
                    guard index + 1 < topLevel.count, topLevel[index + 1].type == "mdat" else {
                        throw Self.fail("moof not followed by mdat")
                    }
                    let fragment = try parseFragment(moof: box, mdat: topLevel[index + 1], bytes: bytes)
                    try write(fragment, from: bytes, to: &output, stats: &stats)
                    index += 1
                default:
                    try output.appendBox(box, from: bytes)
                }
                index += 1
            }
            return (output, stats)
        }
    }

    // MARK: - Parsing

    private struct Fragment {
        let moofChildren: [FMP4Box]
        let trackFragments: [TrackFragment]
    }

    private struct TrackFragment {
        let children: [FMP4Box]
        let isVideo: Bool
        let headerVersion: UInt8
        let headerFlags: UInt32
        let trackID: UInt32
        /// `tfhd` fields after `base_data_offset`, copied as they are.
        let headerTail: Range<Int>
        let runs: [TrackRun]
    }

    private struct TrackRun {
        let version: UInt8
        let flags: UInt32
        let firstSampleFlags: UInt32?
        /// Per-sample entries in the source `trun`.
        let entriesStart: Int
        let entryLength: Int
        /// Where the run's samples start in the source segment.
        let dataStart: Int
        let sampleSizes: [Int]

        var hasSampleSizes: Bool { flags & FMP4FragmentRewriter.sampleSizePresent != 0 }
        var durationLength: Int { flags & FMP4FragmentRewriter.sampleDurationPresent != 0 ? 4 : 0 }
    }

    private func parseFragment(moof: FMP4Box, mdat: FMP4Box, bytes: UnsafeRawBufferPointer) throws -> Fragment {
        let moofChildren = try FMP4Box.boxes(in: bytes, range: moof.payloadStart..<moof.end, failure: Self.fail)
        let mdatPayload = mdat.payloadStart..<mdat.end
        var trackFragments: [TrackFragment] = []
        var previousDataEnd: Int?
        // Budgets across every run of the fragment, so neither many runs nor
        // runs sharing the same bytes can multiply the work or the output:
        // every real sample holds at least one byte, and runs never overlap.
        var remainingSamples = min(max(mdatPayload.count, 1), Self.maximumSamplesPerFragment)
        var remainingBytes = mdatPayload.count

        for traf in moofChildren where traf.type == "traf" {
            let children = try FMP4Box.boxes(in: bytes, range: traf.payloadStart..<traf.end, failure: Self.fail)
            guard let tfhd = children.first(where: { $0.type == "tfhd" }) else { throw Self.fail("traf without tfhd") }
            var header = FMP4Cursor(bytes, payloadOf: tfhd, failure: Self.fail)
            let (headerVersion, headerFlags) = try header.readVersionAndFlags()
            let trackID = try header.read(UInt32.self)
            let baseDataOffset = headerFlags & Self.baseDataOffsetPresent != 0 ? try header.read(UInt64.self) : nil
            let headerTail = header.offset..<tfhd.end
            if headerFlags & Self.sampleDescriptionIndexPresent != 0 { try header.skip(4) }
            if headerFlags & Self.defaultSampleDurationPresent != 0 { try header.skip(4) }
            let headerDefaultSize = headerFlags & Self.defaultSampleSizePresent != 0 ? try header.read(UInt32.self) : nil
            if headerFlags & Self.defaultSampleFlagsPresent != 0 { try header.skip(4) }

            let isVideo = trackID == info.video.trackID
            if let box = children.first(where: { $0.type == "saio" || (isVideo && Self.unsupportedVideoBoxes.contains($0.type)) }) {
                throw Self.fail("\(box.type) in track \(trackID)")
            }

            let base: Int
            if let baseDataOffset {
                guard let offset = Int(exactly: baseDataOffset), offset <= bytes.count else {
                    throw Self.fail("base_data_offset out of range")
                }
                base = offset
            } else if headerFlags & Self.defaultBaseIsMoof != 0 || previousDataEnd == nil {
                base = moof.start
            } else {
                base = previousDataEnd ?? moof.start
            }
            let defaultSize = headerDefaultSize ?? info.trexDefaults[trackID]?.defaultSampleSize

            var nextRunStart = base
            var runs: [TrackRun] = []
            for trun in children where trun.type == "trun" {
                let run = try parseRun(
                    trun,
                    bytes: bytes,
                    base: base,
                    continuingAt: nextRunStart,
                    defaultSize: defaultSize,
                    mdatPayload: mdatPayload,
                    remainingSamples: &remainingSamples,
                    remainingBytes: &remainingBytes
                )
                nextRunStart = run.dataStart + run.sampleSizes.reduce(0, +)
                runs.append(run)
            }
            previousDataEnd = nextRunStart

            trackFragments.append(TrackFragment(
                children: children,
                isVideo: isVideo,
                headerVersion: headerVersion,
                headerFlags: headerFlags,
                trackID: trackID,
                headerTail: headerTail,
                runs: runs
            ))
        }
        return Fragment(moofChildren: moofChildren, trackFragments: trackFragments)
    }

    private func parseRun(
        _ trun: FMP4Box,
        bytes: UnsafeRawBufferPointer,
        base: Int,
        continuingAt previousRunEnd: Int,
        defaultSize: UInt32?,
        mdatPayload: Range<Int>,
        remainingSamples: inout Int,
        remainingBytes: inout Int
    ) throws -> TrackRun {
        var cursor = FMP4Cursor(bytes, payloadOf: trun, failure: Self.fail)
        let (version, flags) = try cursor.readVersionAndFlags()
        let sampleCount = Int(try cursor.read(UInt32.self))
        let dataOffset = flags & Self.dataOffsetPresent != 0 ? Int(try cursor.read(Int32.self)) : nil
        let firstSampleFlags = flags & Self.firstSampleFlagsPresent != 0 ? try cursor.read(UInt32.self) : nil
        let entryLength = (flags & Self.perSampleFields).nonzeroBitCount * 4
        let entriesStart = cursor.offset
        // Checked before anything is allocated for the run.
        guard sampleCount * entryLength <= cursor.remaining, sampleCount <= remainingSamples else {
            throw Self.fail("trun sample count \(sampleCount) out of range")
        }
        remainingSamples -= sampleCount

        let durationLength = flags & Self.sampleDurationPresent != 0 ? 4 : 0
        let dataStart = dataOffset.map { base + $0 } ?? previousRunEnd
        var sampleSizes: [Int] = []
        sampleSizes.reserveCapacity(sampleCount)
        var sampleStart = dataStart
        for sample in 0..<sampleCount {
            let size: Int
            if flags & Self.sampleSizePresent != 0 {
                size = Int(bytes.bigEndianValue(at: entriesStart + sample * entryLength + durationLength, as: UInt32.self))
            } else if let defaultSize {
                size = Int(defaultSize)
            } else {
                throw Self.fail("no sample size")
            }
            guard sampleStart >= mdatPayload.lowerBound, sampleStart + size <= mdatPayload.upperBound else {
                throw Self.fail("sample outside its mdat")
            }
            guard size <= remainingBytes else { throw Self.fail("runs overlap in the mdat") }
            remainingBytes -= size
            sampleSizes.append(size)
            sampleStart += size
        }

        return TrackRun(
            version: version,
            flags: flags,
            firstSampleFlags: firstSampleFlags,
            entriesStart: entriesStart,
            entryLength: entryLength,
            dataStart: dataStart,
            sampleSizes: sampleSizes
        )
    }

    // MARK: - Writing

    /// Output positions to fill once the new `mdat` payload is laid out.
    private struct RunPatch {
        let dataOffsetPosition: Int
        /// Position of the first sample's size field, and the entry stride
        /// (video runs only).
        let firstSizePosition: Int?
        let entryStride: Int
    }

    private func write(
        _ fragment: Fragment,
        from bytes: UnsafeRawBufferPointer,
        to output: inout Data,
        stats: inout DolbyVisionSampleStats
    ) throws {
        let moofStart = output.beginBox("moof")
        var patches: [RunPatch] = []
        var trafIndex = 0
        for child in fragment.moofChildren {
            if child.type == "traf" {
                try appendTrackFragment(fragment.trackFragments[trafIndex], from: bytes, to: &output, patches: &patches)
                trafIndex += 1
            } else {
                try output.appendBox(child, from: bytes)
            }
        }
        try output.endBox(at: moofStart)

        let mdatStart = output.beginBox("mdat")
        let payloadStart = output.count
        var runPayloadOffsets: [Int] = []
        runPayloadOffsets.reserveCapacity(patches.count)
        var patchIndex = 0
        for trackFragment in fragment.trackFragments {
            for run in trackFragment.runs {
                runPayloadOffsets.append(output.count - payloadStart)
                if trackFragment.isVideo {
                    let sizes = try appendVideoSamples(of: run, from: bytes, to: &output, stats: &stats)
                    if let position = patches[patchIndex].firstSizePosition {
                        let stride = patches[patchIndex].entryStride
                        output.withUnsafeMutableBytes { buffer in
                            for (sample, size) in sizes.enumerated() {
                                buffer.storeBytes(of: size.bigEndian, toByteOffset: position + sample * stride, as: UInt32.self)
                            }
                        }
                    }
                } else if !run.sampleSizes.isEmpty {
                    let dataEnd = run.dataStart + run.sampleSizes.reduce(0, +)
                    output.appendBytes(UnsafeRawBufferPointer(rebasing: bytes[run.dataStart..<dataEnd]))
                }
                patchIndex += 1
            }
        }

        let payloadSize = output.count - payloadStart
        var mdatHeaderSize = 8
        if payloadSize + 8 <= Int(UInt32.max) {
            output.storeBigEndian(UInt32(payloadSize + 8), at: mdatStart)
        } else {
            var header = Data()
            header.appendBigEndian(UInt32(1))
            header.appendFourCC("mdat")
            header.appendBigEndian(UInt64(payloadSize + 16))
            output.replaceSubrange(mdatStart..<(mdatStart + 8), with: header)
            mdatHeaderSize = 16
        }

        let moofSize = mdatStart - moofStart
        for (patch, runOffset) in zip(patches, runPayloadOffsets) {
            guard let dataOffset = Int32(exactly: moofSize + mdatHeaderSize + runOffset) else {
                throw Self.fail("data_offset past Int32")
            }
            output.storeBigEndian(dataOffset, at: patch.dataOffsetPosition)
        }
    }

    private func appendTrackFragment(
        _ trackFragment: TrackFragment,
        from bytes: UnsafeRawBufferPointer,
        to output: inout Data,
        patches: inout [RunPatch]
    ) throws {
        let start = output.beginBox("traf")
        var runIndex = 0
        for child in trackFragment.children {
            switch child.type {
            case "tfhd":
                let headerStart = output.beginBox("tfhd")
                let flags = trackFragment.headerFlags & ~Self.baseDataOffsetPresent | Self.defaultBaseIsMoof
                output.appendBigEndian(UInt32(trackFragment.headerVersion) << 24 | flags)
                output.appendBigEndian(trackFragment.trackID)
                output.appendBytes(UnsafeRawBufferPointer(rebasing: bytes[trackFragment.headerTail]))
                try output.endBox(at: headerStart)
            case "trun":
                let run = trackFragment.runs[runIndex]
                runIndex += 1
                patches.append(try appendRun(run, isVideo: trackFragment.isVideo, from: bytes, to: &output))
            default:
                try output.appendBox(child, from: bytes)
            }
        }
        try output.endBox(at: start)
    }

    /// The `trun` with `data_offset` (placeholder) and, for video, a size
    /// field (placeholder) in every entry; other fields copied in spec order.
    private func appendRun(
        _ run: TrackRun,
        isVideo: Bool,
        from bytes: UnsafeRawBufferPointer,
        to output: inout Data
    ) throws -> RunPatch {
        let insertsSizes = isVideo && !run.hasSampleSizes
        var flags = run.flags | Self.dataOffsetPresent
        if isVideo { flags |= Self.sampleSizePresent }

        let start = output.beginBox("trun")
        output.appendBigEndian(UInt32(run.version) << 24 | flags)
        output.appendBigEndian(UInt32(run.sampleSizes.count))
        let dataOffsetPosition = output.count
        output.appendBigEndian(Int32(0))
        if let firstSampleFlags = run.firstSampleFlags { output.appendBigEndian(firstSampleFlags) }

        let entriesStart = output.count
        let entriesEnd = run.entriesStart + run.sampleSizes.count * run.entryLength
        if insertsSizes {
            for sample in 0..<run.sampleSizes.count {
                let entry = run.entriesStart + sample * run.entryLength
                let afterDuration = entry + run.durationLength
                output.appendBytes(UnsafeRawBufferPointer(rebasing: bytes[entry..<afterDuration]))
                output.appendBigEndian(UInt32(0))
                output.appendBytes(UnsafeRawBufferPointer(rebasing: bytes[afterDuration..<(entry + run.entryLength)]))
            }
        } else {
            output.appendBytes(UnsafeRawBufferPointer(rebasing: bytes[run.entriesStart..<entriesEnd]))
        }
        try output.endBox(at: start)

        return RunPatch(
            dataOffsetPosition: dataOffsetPosition,
            firstSizePosition: isVideo ? entriesStart + run.durationLength : nil,
            entryStride: run.entryLength + (insertsSizes ? 4 : 0)
        )
    }

    /// Rewrites each video sample of `run` onto `output`; returns the new
    /// sizes. Empty samples stay empty.
    private func appendVideoSamples(
        of run: TrackRun,
        from bytes: UnsafeRawBufferPointer,
        to output: inout Data,
        stats: inout DolbyVisionSampleStats
    ) throws -> [UInt32] {
        var sizes: [UInt32] = []
        sizes.reserveCapacity(run.sampleSizes.count)
        var sampleStart = run.dataStart
        for size in run.sampleSizes {
            // A seek abandons the segment: stop instead of finishing it.
            try Task.checkCancellation()
            let outputStart = output.count
            if size > 0 {
                var sampleStats = try sampleRewriter.rewriteSample(
                    UnsafeRawBufferPointer(rebasing: bytes[sampleStart..<(sampleStart + size)]),
                    nalLengthSize: info.video.nalLengthSize,
                    appendingTo: &output
                )
                sampleStats.sampleCount = 1
                sampleStats.inputBytes = size
                sampleStats.outputBytes = output.count - outputStart
                stats.merge(sampleStats)
            }
            guard let newSize = UInt32(exactly: output.count - outputStart) else { throw Self.fail("sample over 4 GB") }
            sizes.append(newSize)
            sampleStart += size
        }
        return sizes
    }

    private static func fail(_ reason: String) -> DolbyVision7ConversionError {
        .unsupportedFragment(reason)
    }
}
