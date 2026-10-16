import Foundation

/// Track facts a Dolby Vision profile 7 init segment hands the fragment
/// rewriter for the media segments that follow it.
struct FMP4InitInfo: Sendable, Equatable {
    let video: FMP4VideoTrackInfo
    /// `mvex/trex` defaults by track ID.
    let trexDefaults: [UInt32: FMP4TrackDefaults]
}

struct FMP4VideoTrackInfo: Sendable, Equatable {
    let trackID: UInt32
    /// Bytes in each NAL unit's length prefix (`hvcC` lengthSizeMinusOne + 1).
    let nalLengthSize: Int
}

/// A `trex` box's per-sample fallbacks.
struct FMP4TrackDefaults: Sendable, Equatable {
    let defaultSampleDuration: UInt32
    let defaultSampleSize: UInt32
    let defaultSampleFlags: UInt32
}

/// One ISO BMFF box located inside a byte buffer. Offsets are absolute
/// within that buffer.
struct FMP4Box {
    let type: String
    let start: Int
    /// 8, or 16 for a 64-bit `largesize` header.
    let headerSize: Int
    let end: Int
    /// The header declared size 0 ("extends to the end of the file").
    let extendsToEnd: Bool

    var payloadStart: Int { start + headerSize }
    var size: Int { end - start }

    /// The run of sibling boxes filling `range`. Size 0 extends a box to
    /// the end of `range`; size 1 reads the 64-bit `largesize`.
    static func boxes(
        in bytes: UnsafeRawBufferPointer,
        range: Range<Int>,
        failure: (String) -> DolbyVision7ConversionError
    ) throws -> [FMP4Box] {
        var boxes: [FMP4Box] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard range.upperBound - offset >= 8 else { throw failure("truncated box header") }
            let declared = bytes.bigEndianValue(at: offset, as: UInt32.self)
            let type = bytes.fourCC(at: offset + 4)
            let headerSize: Int
            let end: Int
            switch declared {
            case 0:
                headerSize = 8
                end = range.upperBound
            case 1:
                guard range.upperBound - offset >= 16 else { throw failure("truncated \(type) largesize") }
                let largeSize = bytes.bigEndianValue(at: offset + 8, as: UInt64.self)
                guard largeSize >= 16, largeSize <= UInt64(range.upperBound - offset) else {
                    throw failure("\(type) size \(largeSize) out of bounds")
                }
                headerSize = 16
                end = offset + Int(largeSize)
            default:
                guard declared >= 8, Int(declared) <= range.upperBound - offset else {
                    throw failure("\(type) size \(declared) out of bounds")
                }
                headerSize = 8
                end = offset + Int(declared)
            }
            boxes.append(FMP4Box(type: type, start: offset, headerSize: headerSize, end: end, extendsToEnd: declared == 0))
            offset = end
        }
        return boxes
    }
}

/// Sequential big-endian reads inside one box; every read is bounds-checked
/// against `end`.
struct FMP4Cursor {
    let bytes: UnsafeRawBufferPointer
    private(set) var offset: Int
    let end: Int
    let failure: (String) -> DolbyVision7ConversionError

    init(
        _ bytes: UnsafeRawBufferPointer,
        from offset: Int,
        to end: Int,
        failure: @escaping (String) -> DolbyVision7ConversionError
    ) {
        self.bytes = bytes
        self.offset = offset
        self.end = end
        self.failure = failure
    }

    init(_ bytes: UnsafeRawBufferPointer, payloadOf box: FMP4Box, failure: @escaping (String) -> DolbyVision7ConversionError) {
        self.init(bytes, from: box.payloadStart, to: box.end, failure: failure)
    }

    var remaining: Int { end - offset }

    mutating func skip(_ count: Int) throws {
        try require(count)
        offset += count
    }

    mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        try require(MemoryLayout<T>.size)
        defer { offset += MemoryLayout<T>.size }
        return bytes.bigEndianValue(at: offset, as: T.self)
    }

    mutating func readFourCC() throws -> String {
        try require(4)
        defer { offset += 4 }
        return bytes.fourCC(at: offset)
    }

    /// A full box's version (8 bits) and flags (24 bits).
    mutating func readVersionAndFlags() throws -> (version: UInt8, flags: UInt32) {
        let word = try read(UInt32.self)
        return (UInt8(word >> 24), word & 0x00FF_FFFF)
    }

    private func require(_ count: Int) throws {
        guard count >= 0, count <= end - offset else { throw failure("box field past its end") }
    }
}

extension UnsafeRawBufferPointer {
    /// Unchecked; callers bounds-check first.
    func bigEndianValue<T: FixedWidthInteger>(at offset: Int, as _: T.Type) -> T {
        T(bigEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }

    func fourCC(at offset: Int) -> String {
        String(decoding: self[offset..<(offset + 4)], as: UTF8.self)
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendFourCC(_ type: String) {
        append(contentsOf: Array(type.utf8.prefix(4)))
    }

    mutating func appendBytes(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        append(base.assumingMemoryBound(to: UInt8.self), count: bytes.count)
    }

    /// Overwrites a big-endian field at a 0-based offset.
    mutating func storeBigEndian<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        withUnsafeMutableBytes { $0.storeBytes(of: value.bigEndian, toByteOffset: offset, as: T.self) }
    }

    /// Starts a box with a 32-bit size placeholder; returns its offset for
    /// `endBox`.
    mutating func beginBox(_ type: String) -> Int {
        let start = count
        appendBigEndian(UInt32(0))
        appendFourCC(type)
        return start
    }

    /// Writes the size of the box begun at `start`. Only for boxes that
    /// cannot outgrow 32 bits (everything but `mdat`).
    mutating func endBox(at start: Int) throws {
        let size = count - start
        guard size <= UInt32.max else { throw DolbyVision7ConversionError.unsupportedFragment("box over 4 GB") }
        storeBigEndian(UInt32(size), at: start)
    }

    /// Copies `box` from `bytes` unchanged, except that a size-0 header is
    /// replaced by an explicit size (it no longer ends the file).
    mutating func appendBox(_ box: FMP4Box, from bytes: UnsafeRawBufferPointer) throws {
        guard box.extendsToEnd else {
            appendBytes(UnsafeRawBufferPointer(rebasing: bytes[box.start..<box.end]))
            return
        }
        let start = beginBox(box.type)
        appendBytes(UnsafeRawBufferPointer(rebasing: bytes[box.payloadStart..<box.end]))
        try endBox(at: start)
    }
}
