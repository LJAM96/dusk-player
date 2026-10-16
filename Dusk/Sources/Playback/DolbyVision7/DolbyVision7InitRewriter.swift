import Foundation

/// Rewrites the fMP4 init segment of a Dolby Vision profile 7 remux for the
/// profile 8.1 samples `FMP4FragmentRewriter` produces.
///
/// The single video track keeps (or gets) an `hvc1` sample entry — 8.1's
/// HDR10 base layer is plain HEVC — and its Dolby Vision configuration is
/// replaced by an 8.1 `dvvC`, the packaging `DolbyVisionSignaling` uses for
/// native profile 8. `hev1`/`dvhe` entries keep parameter sets in-band and
/// are not supported (the caller falls back to the unconverted remux).
/// Every other track is copied byte for byte.
enum DolbyVision7InitRewriter {
    /// Bytes between a container's header and its first child.
    private static let containerHeaderPadding: [String: Int] = [
        "trak": 0, "mdia": 0, "minf": 0, "stbl": 0,
        "stsd": 8,    // full box header + entry count
    ]

    /// VisualSampleEntry fields between the box header and its child boxes.
    private static let visualSampleEntryFieldsLength = 78

    private static let convertibleSampleEntries: Set<String> = ["hvc1", "dvh1"]
    private static let dolbyVisionConfigurationBoxes: Set<String> = ["dvcC", "dvvC", "dvwC"]

    static func rewrite(_ data: Data, target: DolbyVisionConfiguration) throws -> (data: Data, info: FMP4InitInfo) {
        try data.withUnsafeBytes { bytes in
            let topLevel = try FMP4Box.boxes(in: bytes, range: 0..<bytes.count, failure: fail)
            guard let moov = topLevel.first(where: { $0.type == "moov" }) else { throw fail("no moov box") }
            let moovChildren = try children(of: moov, in: bytes)

            var videoTraks: [(box: FMP4Box, trackID: UInt32)] = []
            for trak in moovChildren where trak.type == "trak" {
                let track = try trackHeader(of: trak, in: bytes)
                if track.handler == "vide" { videoTraks.append((trak, track.trackID)) }
            }
            guard videoTraks.count == 1, let videoTrak = videoTraks.first else {
                throw fail("\(videoTraks.count) video tracks")
            }
            let trexDefaults = try trackDefaults(in: moovChildren, bytes: bytes)

            var output = Data()
            output.reserveCapacity(bytes.count + 64)
            var nalLengthSize: Int?
            for box in topLevel {
                switch box.type {
                case "ftyp":
                    try appendFileType(box, from: bytes, to: &output)
                case "moov":
                    let start = output.beginBox("moov")
                    for child in moovChildren {
                        if child.start == videoTrak.box.start {
                            try appendVideoBox(child, from: bytes, to: &output, target: target, nalLengthSize: &nalLengthSize)
                        } else {
                            try output.appendBox(child, from: bytes)
                        }
                    }
                    try output.endBox(at: start)
                default:
                    try output.appendBox(box, from: bytes)
                }
            }
            guard let nalLengthSize else { throw fail("video track has no sample entry") }

            let info = FMP4InitInfo(
                video: FMP4VideoTrackInfo(trackID: videoTrak.trackID, nalLengthSize: nalLengthSize),
                trexDefaults: trexDefaults
            )
            return (output, info)
        }
    }

    private static func fail(_ reason: String) -> DolbyVision7ConversionError {
        .unsupportedInitSegment(reason)
    }

    private static func children(of box: FMP4Box, in bytes: UnsafeRawBufferPointer, padding: Int = 0) throws -> [FMP4Box] {
        let start = box.payloadStart + padding
        guard start <= box.end else { throw fail("\(box.type) too short") }
        return try FMP4Box.boxes(in: bytes, range: start..<box.end, failure: fail)
    }

    /// `tkhd` track_ID and `mdia/hdlr` handler_type of a `trak`.
    private static func trackHeader(
        of trak: FMP4Box,
        in bytes: UnsafeRawBufferPointer
    ) throws -> (trackID: UInt32, handler: String?) {
        let trakChildren = try children(of: trak, in: bytes)
        guard let tkhd = trakChildren.first(where: { $0.type == "tkhd" }) else { throw fail("trak without tkhd") }
        var cursor = FMP4Cursor(bytes, payloadOf: tkhd, failure: fail)
        let (version, _) = try cursor.readVersionAndFlags()
        try cursor.skip(version == 1 ? 16 : 8)    // creation + modification time
        let trackID = try cursor.read(UInt32.self)

        guard let mdia = trakChildren.first(where: { $0.type == "mdia" }),
              let hdlr = try children(of: mdia, in: bytes).first(where: { $0.type == "hdlr" }) else {
            return (trackID, nil)
        }
        var handlerCursor = FMP4Cursor(bytes, payloadOf: hdlr, failure: fail)
        try handlerCursor.skip(8)    // version/flags + pre_defined
        return (trackID, try handlerCursor.readFourCC())
    }

    private static func trackDefaults(
        in moovChildren: [FMP4Box],
        bytes: UnsafeRawBufferPointer
    ) throws -> [UInt32: FMP4TrackDefaults] {
        guard let mvex = moovChildren.first(where: { $0.type == "mvex" }) else { return [:] }
        var defaults: [UInt32: FMP4TrackDefaults] = [:]
        for trex in try children(of: mvex, in: bytes) where trex.type == "trex" {
            var cursor = FMP4Cursor(bytes, payloadOf: trex, failure: fail)
            try cursor.skip(4)    // version/flags
            let trackID = try cursor.read(UInt32.self)
            try cursor.skip(4)    // default_sample_description_index
            defaults[trackID] = FMP4TrackDefaults(
                defaultSampleDuration: try cursor.read(UInt32.self),
                defaultSampleSize: try cursor.read(UInt32.self),
                defaultSampleFlags: try cursor.read(UInt32.self)
            )
        }
        return defaults
    }

    /// `ftyp` with the `dby1` compatible brand Dolby Vision fMP4 carries.
    private static func appendFileType(_ ftyp: FMP4Box, from bytes: UnsafeRawBufferPointer, to output: inout Data) throws {
        let payload = UnsafeRawBufferPointer(rebasing: bytes[ftyp.payloadStart..<ftyp.end])
        let brands = stride(from: 8, to: payload.count - 3, by: 4).map { payload.fourCC(at: $0) }
        guard payload.count >= 8, payload.count % 4 == 0, !brands.contains("dby1") else {
            try output.appendBox(ftyp, from: bytes)
            return
        }
        let start = output.beginBox("ftyp")
        output.appendBytes(payload)
        output.appendFourCC("dby1")
        try output.endBox(at: start)
    }

    /// Rebuilds the video `trak` down to its sample entries; boxes off that
    /// path are copied.
    private static func appendVideoBox(
        _ box: FMP4Box,
        from bytes: UnsafeRawBufferPointer,
        to output: inout Data,
        target: DolbyVisionConfiguration,
        nalLengthSize: inout Int?
    ) throws {
        guard let padding = containerHeaderPadding[box.type] else {
            try output.appendBox(box, from: bytes)
            return
        }
        let boxChildren = try children(of: box, in: bytes, padding: padding)
        let start = output.beginBox(box.type)
        output.appendBytes(UnsafeRawBufferPointer(rebasing: bytes[box.payloadStart..<(box.payloadStart + padding)]))
        for child in boxChildren {
            if box.type == "stsd" {
                try appendSampleEntry(child, from: bytes, to: &output, target: target, nalLengthSize: &nalLengthSize)
            } else {
                try appendVideoBox(child, from: bytes, to: &output, target: target, nalLengthSize: &nalLengthSize)
            }
        }
        try output.endBox(at: start)
    }

    /// `hvc1`/`dvh1` → `hvc1` with its children minus any Dolby Vision
    /// configuration box, then the 8.1 `dvvC`.
    private static func appendSampleEntry(
        _ entry: FMP4Box,
        from bytes: UnsafeRawBufferPointer,
        to output: inout Data,
        target: DolbyVisionConfiguration,
        nalLengthSize: inout Int?
    ) throws {
        guard convertibleSampleEntries.contains(entry.type) else {
            throw fail("video sample entry \(entry.type)")
        }
        let entryChildren = try children(of: entry, in: bytes, padding: visualSampleEntryFieldsLength)
        guard let hvcC = entryChildren.first(where: { $0.type == "hvcC" }) else { throw fail("\(entry.type) without hvcC") }
        // HEVCDecoderConfigurationRecord byte 21: constantFrameRate(2)
        // numTemporalLayers(3) temporalIdNested(1) lengthSizeMinusOne(2).
        var cursor = FMP4Cursor(bytes, payloadOf: hvcC, failure: fail)
        try cursor.skip(21)
        let entryLengthSize = Int(try cursor.read(UInt8.self) & 0x03) + 1
        if let nalLengthSize, nalLengthSize != entryLengthSize {
            throw fail("sample entries disagree on NAL length size")
        }
        nalLengthSize = entryLengthSize

        let start = output.beginBox("hvc1")
        let fieldsStart = entry.payloadStart
        output.appendBytes(UnsafeRawBufferPointer(rebasing: bytes[fieldsStart..<(fieldsStart + visualSampleEntryFieldsLength)]))
        for child in entryChildren where !dolbyVisionConfigurationBoxes.contains(child.type) {
            try output.appendBox(child, from: bytes)
        }
        output.append(contentsOf: DolbyVisionSignaling.configurationBox(target))
        try output.endBox(at: start)
    }
}
