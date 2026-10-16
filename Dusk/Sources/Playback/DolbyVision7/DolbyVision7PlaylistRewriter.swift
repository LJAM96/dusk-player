import Foundation

/// Rewrites a Plex fMP4 HLS remux's playlists so a Dolby Vision profile 7
/// stream plays as profile 8.1 through the local conversion proxy.
///
/// Every URI is resolved against the playlist's URL and handed to the
/// `URLMapper`: variant and rendition playlists, the `EXT-X-MAP` init
/// segment, and media segments (with the init segment in effect, so the
/// proxy knows which track layout a segment belongs to). Variants gain the
/// backward-compatible 8.1 signaling `DolbyVisionSignaling` writes for
/// native profile 8; I-frame variants are dropped (their samples would not
/// be converted). Anything the proxy cannot serve converted — byte ranges,
/// encryption, a variant that cannot carry `dvh1.08` — throws
/// `.unsupportedPlaylist` so the caller falls back to the plain remux.
enum DolbyVision7PlaylistRewriter {
    struct URLMapper: Sendable {
        let playlist: @Sendable (URL) -> URL
        let initSegment: @Sendable (URL) -> URL
        let mediaSegment: @Sendable (_ segment: URL, _ initSegment: URL?) -> URL
    }

    static func rewrite(_ text: String, baseURL: URL, target: DolbyVisionConfiguration, mapper: URLMapper) throws -> String {
        var lines: [String] = []
        var nextURIIsVariant = false
        var currentMap: URL?

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                lines.append(try variantLine(line, target: target))
                nextURIIsVariant = true
            } else if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") {
                continue
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                lines.append(try mappingURIAttribute(in: line, baseURL: baseURL, using: mapper.playlist))
            } else if line.hasPrefix("#EXT-X-MAP") {
                guard let attributes = HLSAttributeList(line: line),
                      attributes.quotedValue(of: "BYTERANGE") == nil,
                      let uri = attributes.quotedValue(of: "URI") else {
                    throw DolbyVision7ConversionError.unsupportedPlaylist("EXT-X-MAP without a plain URI")
                }
                let initSegment = try resolve(uri, against: baseURL)
                currentMap = initSegment
                var mapped = attributes
                mapped.setQuoted("URI", to: mapper.initSegment(initSegment).absoluteString)
                lines.append(mapped.line)
            } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                throw DolbyVision7ConversionError.unsupportedPlaylist("EXT-X-BYTERANGE")
            } else if line.hasPrefix("#EXT-X-KEY") {
                let method = HLSAttributeList(line: line)?.value(of: "METHOD")
                guard method == "NONE" else {
                    throw DolbyVision7ConversionError.unsupportedPlaylist("EXT-X-KEY METHOD=\(method ?? "?")")
                }
                lines.append(line)
            } else if line.isEmpty || line.hasPrefix("#") {
                lines.append(line)
            } else {
                let url = try resolve(line, against: baseURL)
                if nextURIIsVariant {
                    lines.append(mapper.playlist(url).absoluteString)
                    nextURIIsVariant = false
                } else {
                    lines.append(mapper.mediaSegment(url, currentMap).absoluteString)
                }
            }
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The variant with 8.1 signaling, which must have landed: an `hvc1`
    /// entry kept in `CODECS` and the target's `dvh1.08` in
    /// `SUPPLEMENTAL-CODECS` (a `hev1`, non-HEVC or `dvh1.07` variant is
    /// left alone by `rewrittenStreamInfLine`).
    private static func variantLine(_ line: String, target: DolbyVisionConfiguration) throws -> String {
        let rewritten = DolbyVisionSignaling.rewrittenStreamInfLine(line, configuration: target)
        let attributes = HLSAttributeList(line: rewritten)
        let codecs = codecList(attributes?.quotedValue(of: "CODECS"))
        let supplemental = codecList(attributes?.quotedValue(of: "SUPPLEMENTAL-CODECS"))
        guard let expected = target.supplementalCodecString,
              supplemental.contains(expected.lowercased()),
              codecs.contains(where: { $0.hasPrefix("hvc1") }),
              !codecs.contains(where: { $0.hasPrefix("hev1") }) else {
            throw DolbyVision7ConversionError.unsupportedPlaylist("variant cannot carry Dolby Vision 8.1")
        }
        return rewritten
    }

    private static func codecList(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private static func mappingURIAttribute(
        in line: String,
        baseURL: URL,
        using map: (URL) -> URL
    ) throws -> String {
        guard line.contains("URI=") else { return line }
        guard var attributes = HLSAttributeList(line: line), let uri = attributes.quotedValue(of: "URI") else {
            throw DolbyVision7ConversionError.unsupportedPlaylist("unparseable URI attribute")
        }
        attributes.setQuoted("URI", to: map(try resolve(uri, against: baseURL)).absoluteString)
        return attributes.line
    }

    /// RFC 3986 resolution: a relative reference drops the base's query and
    /// keeps its own.
    private static func resolve(_ uri: String, against baseURL: URL) throws -> URL {
        guard let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else {
            throw DolbyVision7ConversionError.unsupportedPlaylist("unresolvable URI")
        }
        return url
    }
}
