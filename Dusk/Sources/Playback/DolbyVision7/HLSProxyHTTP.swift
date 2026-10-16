import Foundation

/// The HTTP/1.1 subset `DolbyVision7HLSProxy` speaks to AVPlayer: one
/// GET/HEAD request per connection, an optional single byte range, and a
/// fully buffered response followed by `Connection: close`.
struct HLSProxyRequest: Sendable, Equatable {
    /// Requests whose head exceeds this are refused rather than buffered.
    static let maximumHeadLength = 16 * 1024

    let method: String
    let path: String
    let query: String?
    let range: HLSProxyByteRange?

    var isHead: Bool { method == "HEAD" }

    /// Length of the request head (through the blank line) in `data`, or nil
    /// while it is still incomplete.
    static func headLength(in data: Data) -> Int? {
        data.firstRange(of: Data("\r\n\r\n".utf8)).map { $0.upperBound - data.startIndex }
    }

    /// Parses a complete request head. Nil for anything malformed; a range
    /// header this proxy cannot serve (several ranges, other units) is
    /// ignored, which HTTP allows.
    static func parse(_ head: Data) -> HLSProxyRequest? {
        guard head.count <= maximumHeadLength,
              let text = String(data: head, encoding: .utf8) else {
            return nil
        }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3,
              requestLine[2].hasPrefix("HTTP/1."),
              !requestLine[0].isEmpty,
              requestLine[1].hasPrefix("/") else {
            return nil
        }

        let target = requestLine[1]
        let path: Substring
        let query: Substring?
        if let mark = target.firstIndex(of: "?") {
            path = target[..<mark]
            query = target[target.index(after: mark)...]
        } else {
            path = target
            query = nil
        }

        var range: HLSProxyByteRange?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("Range") == .orderedSame else { continue }
            range = HLSProxyByteRange(headerValue: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }

        return HLSProxyRequest(
            method: String(requestLine[0]),
            path: String(path),
            query: query.map(String.init),
            range: range
        )
    }
}

/// One `bytes=` range, resolved against the body once its length is known.
enum HLSProxyByteRange: Sendable, Equatable {
    /// `bytes=first-` or `bytes=first-last`.
    case from(Int, through: Int?)
    /// `bytes=-count`: the last `count` bytes.
    case suffix(Int)

    init?(headerValue: String) {
        guard headerValue.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = headerValue.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let first = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let last = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            guard let count = Int(last), count >= 0 else { return nil }
            self = .suffix(count)
        } else {
            guard let start = Int(first), start >= 0 else { return nil }
            if last.isEmpty {
                self = .from(start, through: nil)
            } else {
                guard let end = Int(last), end >= start else { return nil }
                self = .from(start, through: end)
            }
        }
    }

    /// The byte offsets to send for a body of `length` bytes, or nil when the
    /// range is unsatisfiable (416).
    func resolved(length: Int) -> ClosedRange<Int>? {
        guard length > 0 else { return nil }
        switch self {
        case let .from(start, end):
            guard start < length else { return nil }
            return start...min(end ?? length - 1, length - 1)
        case let .suffix(count):
            guard count > 0 else { return nil }
            return max(0, length - count)...(length - 1)
        }
    }
}

/// A fully buffered response; `serialized(for:)` applies the request's range
/// and HEAD semantics.
struct HLSProxyResponse: Sendable {
    static let playlistContentType = "application/vnd.apple.mpegurl"
    static let mp4ContentType = "video/mp4"

    var status: Int
    var contentType: String
    var body: Data

    static func empty(_ status: Int) -> HLSProxyResponse {
        HLSProxyResponse(status: status, contentType: "text/plain", body: Data())
    }

    func serialized(for request: HLSProxyRequest?) -> Data {
        var status = status
        var body = body
        var headers = [
            "Content-Type": contentType,
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
            "Connection": "close",
        ]

        if status == 200, let range = request?.range {
            let total = body.count
            if let resolved = range.resolved(length: total) {
                status = 206
                headers["Content-Range"] = "bytes \(resolved.lowerBound)-\(resolved.upperBound)/\(total)"
                let start = body.startIndex + resolved.lowerBound
                body = body.subdata(in: start..<(start + resolved.count))
            } else {
                status = 416
                headers["Content-Range"] = "bytes */\(total)"
                body = Data()
            }
        }
        headers["Content-Length"] = String(body.count)

        var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(for: status))\r\n"
        for name in headers.keys.sorted() {
            head += "\(name): \(headers[name] ?? "")\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        if request?.isHead != true {
            data.append(body)
        }
        return data
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        default: HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        }
    }
}
