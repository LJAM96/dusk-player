import Foundation
import Network
import OSLog

private let dolbyVision7Logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "DolbyVision7"
)

/// Upstream GETs for `DolbyVision7HLSProxy`; a seam for tests.
protocol HLSUpstreamFetching: Sendable {
    func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse)
}

/// Fetches Plex's remux playlists and segments verbatim (query included),
/// uncached: every segment is converted once and never kept.
struct URLSessionHLSUpstreamFetcher: HLSUpstreamFetching {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Loopback HTTP server that turns Plex's fMP4 remux of a Dolby Vision
/// profile 7 file into profile 8.1 on the fly, for AVPlayer.
///
/// Apple has no profile 7 decoder, and an `AVAssetResourceLoader` cannot
/// serve HLS media segments, so every playlist, init segment and video
/// segment passes through here instead. The master playlist gains
/// `SUPPLEMENTAL-CODECS="dvh1.08.LL/db1p"`, the init segment a `dvvC`
/// (`DolbyVision7InitRewriter`), and each media segment has its enhancement
/// layer dropped and its RPUs rewritten as 8.1 (`FMP4FragmentRewriter`,
/// libdovi through `DoviBridge`). WebVTT renditions (no `EXT-X-MAP`) stay
/// pointed at the server.
///
/// Anything that cannot be converted reports through `onFatalError` once;
/// `AVPlayerEngine` turns that into an engine error and the coordinator
/// retries the same remux without conversion (docs/playback.md →
/// "Dolby Vision 7 (on-device 8.1 conversion)").
///
/// Only reachable from this device (loopback interface, local-only), only
/// under a random per-session path token, and only relays URLs on the
/// master playlist's own origin.
final class DolbyVision7HLSProxy: @unchecked Sendable {
    /// Segments fetched and converted at once. Each is buffered whole, so
    /// this bounds the proxy's memory to a few segments.
    private static let maximumConcurrentSegments = 2

    private let upstreamMasterURL: URL
    private let target: DolbyVisionConfiguration
    private let restoresDolbyAtmos: Bool
    private let sampleRewriter: any DolbyVisionSampleRewriting
    private let fetcher: any HLSUpstreamFetching
    private let token: String
    private let queue = DispatchQueue(label: "com.dusk-player.dolby-vision-7-proxy")
    private let segmentGate = HLSProxySegmentGate(limit: maximumConcurrentSegments)

    private let lock = NSLock()
    // Everything below is guarded by `lock`.
    private var fatalErrorHandler: (@Sendable (DolbyVision7ConversionError) -> Void)?
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<NWEndpoint.Port, any Error>?
    private var port: NWEndpoint.Port?
    private var hasRecreatedListener = false
    private var isStopped = false
    private var didReportFatalError = false
    private var didLogFirstSegment = false
    private var didWarnAboutMissingRPUs = false
    private var masterPlaylist: Data?
    private var initIDsByURL: [URL: Int] = [:]
    private var initURLsByID: [Int: URL] = [:]
    private var initSegments: [Int: (data: Data, info: FMP4InitInfo)] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requestTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Called once, on an arbitrary queue, when conversion cannot continue.
    var onFatalError: (@Sendable (DolbyVision7ConversionError) -> Void)? {
        get { lock.withLock { fatalErrorHandler } }
        set { lock.withLock { fatalErrorHandler = newValue } }
    }

    init(
        upstreamMasterURL: URL,
        target: DolbyVisionConfiguration,
        restoresDolbyAtmos: Bool,
        sampleRewriter: any DolbyVisionSampleRewriting = DoviBridgeSampleRewriter(),
        fetcher: any HLSUpstreamFetching = URLSessionHLSUpstreamFetcher()
    ) {
        self.upstreamMasterURL = upstreamMasterURL
        self.target = target
        self.restoresDolbyAtmos = restoresDolbyAtmos
        self.sampleRewriter = sampleRewriter
        self.fetcher = fetcher
        self.token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    deinit {
        stop()
    }

    /// Binds the listener and checks the remux can be converted at all: the
    /// master playlist takes 8.1 signaling, its first variant is fMP4
    /// (`EXT-X-MAP`) and that init segment converts. Returns the master
    /// playlist URL to hand AVPlayer. Segment 0 is not prefetched.
    func start() async throws -> URL {
        do {
            let port = try await startListener(on: .any)
            try await preflight()
            guard let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/master.m3u8") else {
                throw DolbyVision7ConversionError.proxyUnavailable("could not build the loopback URL")
            }
            dolbyVision7Logger.notice(
                "Dolby Vision 7 → 8.1 proxy ready on loopback port \(port.rawValue, privacy: .public) (Atmos patch: \(self.restoresDolbyAtmos ? "yes" : "no", privacy: .public))"
            )
            return url
        } catch {
            stop()
            throw Self.conversionError(error)
        }
    }

    /// Closes the listener and every connection and drops all cached state.
    /// Idempotent.
    func stop() {
        let teardown = lock.withLock {
            isStopped = true
            let teardown = (
                listener: listener,
                continuation: readyContinuation,
                connections: Array(connections.values),
                tasks: Array(requestTasks.values)
            )
            listener = nil
            readyContinuation = nil
            connections = [:]
            requestTasks = [:]
            masterPlaylist = nil
            initSegments = [:]
            return teardown
        }
        teardown.continuation?.resume(throwing: CancellationError())
        teardown.tasks.forEach { $0.cancel() }
        teardown.connections.forEach { $0.cancel() }
        teardown.listener?.newConnectionHandler = nil
        teardown.listener?.stateUpdateHandler = nil
        teardown.listener?.cancel()
    }

    // MARK: - Listener

    private func startListener(on requestedPort: NWEndpoint.Port) async throws -> NWEndpoint.Port {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: requestedPort)
        let listener = try NWListener(using: parameters)

        return try await withCheckedThrowingContinuation { continuation in
            let isAccepted = lock.withLock {
                guard !isStopped else { return false }
                self.listener = listener
                readyContinuation = continuation
                return true
            }
            guard isAccepted else {
                continuation.resume(throwing: CancellationError())
                return
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                self.listener(listener, didChange: state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func listener(_ listener: NWListener, didChange state: NWListener.State) {
        switch state {
        case .ready:
            let continuation = lock.withLock {
                port = listener.port
                defer { readyContinuation = nil }
                return readyContinuation
            }
            if let port = listener.port {
                continuation?.resume(returning: port)
            } else {
                continuation?.resume(throwing: DolbyVision7ConversionError.proxyUnavailable("listener has no port"))
            }
        case let .failed(error):
            listener.cancel()
            let continuation = lock.withLock {
                defer { readyContinuation = nil }
                return readyContinuation
            }
            if let continuation {
                continuation.resume(throwing: DolbyVision7ConversionError.proxyUnavailable("listener failed: \(error)"))
            } else {
                listenerFailedAfterStart(listener, error: error)
            }
        case .cancelled:
            let continuation = lock.withLock {
                defer { readyContinuation = nil }
                return readyContinuation
            }
            continuation?.resume(throwing: CancellationError())
        default:
            break
        }
    }

    /// iOS can tear the listener down while the app is suspended. Re-create
    /// it once on the same port (the playlists AVPlayer holds name it);
    /// after that, conversion is over.
    private func listenerFailedAfterStart(_ listener: NWListener, error: NWError) {
        let restartPort: NWEndpoint.Port? = lock.withLock {
            guard !isStopped, self.listener === listener, !hasRecreatedListener, let port else { return nil }
            hasRecreatedListener = true
            return port
        }
        guard let restartPort else {
            reportFatal(.proxyUnavailable("loopback listener failed: \(error)"))
            return
        }
        dolbyVision7Logger.notice("Loopback listener failed (\(String(describing: error), privacy: .public)); re-creating it once")
        Task { [weak self] in
            do {
                _ = try await self?.startListener(on: restartPort)
            } catch {
                self?.reportFatal(.proxyUnavailable("could not re-create the loopback listener"))
            }
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let isAccepted = lock.withLock {
            guard !isStopped else { return false }
            connections[key] = connection
            return true
        }
        guard isAccepted else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connectionClosed(key)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveHead(on: connection, buffered: Data())
    }

    private func receiveHead(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffered = buffered
            if let content {
                buffered.append(content)
            }
            if let headLength = HLSProxyRequest.headLength(in: buffered) {
                self.handle(HLSProxyRequest.parse(buffered.prefix(headLength)), on: connection)
            } else if buffered.count > HLSProxyRequest.maximumHeadLength {
                self.send(.empty(431), for: nil, on: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.receiveHead(on: connection, buffered: buffered)
            }
        }
    }

    private func handle(_ request: HLSProxyRequest?, on connection: NWConnection) {
        guard let request else {
            send(.empty(400), for: nil, on: connection)
            return
        }
        let key = ObjectIdentifier(connection)
        let task = Task { [weak self] in
            guard let self else { return }
            let response = await self.response(for: request)
            guard !Task.isCancelled else { return }
            self.send(response, for: request, on: connection)
        }
        let isOpen = lock.withLock {
            guard connections[key] != nil else { return false }
            requestTasks[key] = task
            return true
        }
        if !isOpen {
            task.cancel()
        }
    }

    private func send(_ response: HLSProxyResponse, for request: HLSProxyRequest?, on connection: NWConnection) {
        connection.send(
            content: response.serialized(for: request),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    /// The player closed the connection (or it failed): drop it and stop
    /// fetching or converting for it.
    private func connectionClosed(_ key: ObjectIdentifier) {
        let task = lock.withLock {
            connections[key] = nil
            return requestTasks.removeValue(forKey: key)
        }
        task?.cancel()
    }

    // MARK: - Routing

    /// `/<token>/master.m3u8`, `/<token>/p/<upstream>.m3u8` (media and
    /// subtitle playlists), `/<token>/i/<upstream>.mp4` (init segments) and
    /// `/<token>/s/<init id>/<upstream>.m4s` (media segments), where
    /// `<upstream>` is the server URL in unpadded base64url.
    private func response(for request: HLSProxyRequest) async -> HLSProxyResponse {
        guard request.method == "GET" || request.isHead else { return .empty(405) }
        let components = request.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 3, components[0].isEmpty, components[1] == token else {
            return .empty(403)
        }

        do {
            switch (components[2], components.count) {
            case ("master.m3u8", 3):
                guard let master = lock.withLock({ masterPlaylist }) else { return .empty(404) }
                return HLSProxyResponse(status: 200, contentType: HLSProxyResponse.playlistContentType, body: master)
            case ("p", 4):
                guard let upstream = upstreamURL(components[3], fileExtension: "m3u8") else { return .empty(403) }
                return try await playlistResponse(upstream)
            case ("i", 4):
                guard let upstream = upstreamURL(components[3], fileExtension: "mp4") else { return .empty(403) }
                return try await initSegmentResponse(id: initID(for: upstream))
            case ("s", 5):
                guard let initID = Int(components[3]),
                      let upstream = upstreamURL(components[4], fileExtension: "m4s") else {
                    return .empty(403)
                }
                return try await withSegmentPermit {
                    try await self.mediaSegmentResponse(upstream, initID: initID)
                }
            default:
                return .empty(404)
            }
        } catch let error as DolbyVision7ConversionError {
            reportFatal(error)
            return .empty(500)
        } catch {
            if !Task.isCancelled {
                dolbyVision7Logger.error(
                    "Upstream request failed for a /\(components[2], privacy: .public) route: \(error.localizedDescription, privacy: .public)"
                )
            }
            return .empty(502)
        }
    }

    private func playlistResponse(_ upstream: URL) async throws -> HLSProxyResponse {
        let (data, response) = try await fetcher.fetch(upstream)
        guard (200..<300).contains(response.statusCode) else { return .empty(response.statusCode) }
        let playlist = try rewrittenPlaylist(String(decoding: data, as: UTF8.self), baseURL: upstream)
        return HLSProxyResponse(
            status: 200,
            contentType: HLSProxyResponse.playlistContentType,
            body: Data(playlist.utf8)
        )
    }

    private func initSegmentResponse(id: Int) async throws -> HLSProxyResponse {
        switch try await initSegment(id: id) {
        case let .converted(segment):
            return HLSProxyResponse(status: 200, contentType: HLSProxyResponse.mp4ContentType, body: segment.data)
        case let .upstreamStatus(status):
            return .empty(status)
        }
    }

    private func mediaSegmentResponse(_ upstream: URL, initID: Int) async throws -> HLSProxyResponse {
        let info: FMP4InitInfo
        switch try await initSegment(id: initID) {
        case let .converted(segment): info = segment.info
        case let .upstreamStatus(status): return .empty(status)
        }

        let (data, response) = try await fetcher.fetch(upstream)
        guard (200..<300).contains(response.statusCode) else { return .empty(response.statusCode) }
        try Task.checkCancellation()

        let rewriter = FMP4FragmentRewriter(info: info, sampleRewriter: sampleRewriter)
        let converted = try await Task.detached(priority: .userInitiated) {
            try rewriter.rewrite(data)
        }.value
        try check(converted.stats)
        return HLSProxyResponse(status: 200, contentType: HLSProxyResponse.mp4ContentType, body: converted.data)
    }

    // MARK: - Conversion

    private func preflight() async throws {
        let (masterData, masterResponse) = try await fetcher.fetch(upstreamMasterURL)
        guard (200..<300).contains(masterResponse.statusCode) else {
            throw DolbyVision7ConversionError.proxyUnavailable("master playlist returned HTTP \(masterResponse.statusCode)")
        }
        let masterText = String(decoding: masterData, as: UTF8.self)
        guard masterText.contains("#EXT-X-STREAM-INF") else {
            throw DolbyVision7ConversionError.unsupportedPlaylist("no variant in the master playlist")
        }
        let master = try rewrittenPlaylist(masterText, baseURL: upstreamMasterURL)

        guard let variantURL = Self.firstVariantURL(in: masterText, baseURL: upstreamMasterURL),
              isSameOrigin(variantURL) else {
            throw DolbyVision7ConversionError.unsupportedPlaylist("variant playlist is not on the server")
        }
        let variantText = try await variantPlaylistText(variantURL)
        guard variantText.contains("#EXT-X-MAP") else {
            throw DolbyVision7ConversionError.unsupportedPlaylist("variant is not fMP4 (no EXT-X-MAP)")
        }
        _ = try rewrittenPlaylist(variantText, baseURL: variantURL)
        guard let initID = lock.withLock({ initURLsByID.keys.min() }) else {
            throw DolbyVision7ConversionError.unsupportedPlaylist("init segment is not on the server")
        }
        if case let .upstreamStatus(status) = try await initSegment(id: initID) {
            throw DolbyVision7ConversionError.proxyUnavailable("init segment returned HTTP \(status)")
        }

        lock.withLock { masterPlaylist = Data(master.utf8) }
    }

    /// Plex can answer the variant playlist with an error for a moment while
    /// its transcoder spins up.
    private func variantPlaylistText(_ url: URL) async throws -> String {
        var lastStatus = 0
        for attempt in 0..<3 {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(1))
            }
            let (data, response) = try await fetcher.fetch(url)
            if (200..<300).contains(response.statusCode) {
                return String(decoding: data, as: UTF8.self)
            }
            lastStatus = response.statusCode
        }
        throw DolbyVision7ConversionError.proxyUnavailable("variant playlist returned HTTP \(lastStatus)")
    }

    private func rewrittenPlaylist(_ text: String, baseURL: URL) throws -> String {
        try DolbyVision7PlaylistRewriter.rewrite(
            text,
            baseURL: baseURL,
            target: target,
            mapper: .init(
                playlist: { [self] upstream in
                    proxyURL(upstream, route: "p", fileExtension: "m3u8") ?? upstream
                },
                initSegment: { [self] upstream in
                    guard isSameOrigin(upstream) else { return upstream }
                    _ = initID(for: upstream)
                    return proxyURL(upstream, route: "i", fileExtension: "mp4") ?? upstream
                },
                mediaSegment: { [self] segment, initSegment in
                    guard let initSegment, isSameOrigin(initSegment) else { return segment }
                    return proxyURL(segment, route: "s/\(initID(for: initSegment))", fileExtension: "m4s") ?? segment
                }
            )
        )
    }

    private enum InitSegmentLoad {
        case converted((data: Data, info: FMP4InitInfo))
        /// The server answered with this non-2xx status; passed on as is.
        case upstreamStatus(Int)
    }

    /// The converted init segment, fetched once and kept for the session
    /// (every media segment needs its track layout).
    private func initSegment(id: Int) async throws -> InitSegmentLoad {
        let cached = lock.withLock { (initSegments[id], initURLsByID[id]) }
        if let segment = cached.0 { return .converted(segment) }
        guard let upstream = cached.1 else { return .upstreamStatus(404) }

        let (data, response) = try await fetcher.fetch(upstream)
        guard (200..<300).contains(response.statusCode) else {
            return .upstreamStatus(response.statusCode)
        }
        var converted = try DolbyVision7InitRewriter.rewrite(data, target: target)
        if restoresDolbyAtmos, let patched = EAC3JOCSignaling.patchedInitSegment(converted.data) {
            converted.data = patched
        }
        dolbyVision7Logger.notice(
            "Converted the init segment to \(self.target.displayName, privacy: .public): video track \(converted.info.video.trackID, privacy: .public), NAL length \(converted.info.video.nalLengthSize, privacy: .public)"
        )
        lock.withLock { initSegments[id] = converted }
        return .converted(converted)
    }

    private func initID(for upstream: URL) -> Int {
        lock.withLock {
            if let id = initIDsByURL[upstream] { return id }
            let id = initURLsByID.count
            initIDsByURL[upstream] = id
            initURLsByID[id] = upstream
            return id
        }
    }

    /// A video segment with frames but no RPU is not Dolby Vision 7 (or lost
    /// its RPUs on the way): signalling it as 8.1 would be wrong.
    private func check(_ stats: DolbyVisionSampleStats) throws {
        if stats.sampleCount > 0 && stats.rpuCount == 0 {
            throw DolbyVision7ConversionError.missingRPU
        }
        let (isFirst, warnsAboutRPUs) = lock.withLock {
            defer { didLogFirstSegment = true }
            let warns = stats.rpuCount < stats.sampleCount && !didWarnAboutMissingRPUs
            if warns { didWarnAboutMissingRPUs = true }
            return (!didLogFirstSegment, warns)
        }
        if isFirst {
            dolbyVision7Logger.notice(
                "First converted segment: profile \(stats.sourceProfile.map(String.init) ?? "?", privacy: .public), EL \(String(describing: stats.sourceELType), privacy: .public), \(stats.sampleCount, privacy: .public) samples, \(stats.rpuCount, privacy: .public) RPUs, \(stats.enhancementLayerNALCount, privacy: .public) EL NALs dropped, \(stats.inputBytes, privacy: .public) → \(stats.outputBytes, privacy: .public) bytes"
            )
        }
        if warnsAboutRPUs {
            dolbyVision7Logger.warning(
                "Segment has \(stats.rpuCount, privacy: .public) RPUs for \(stats.sampleCount, privacy: .public) samples; frames without one play as HDR10"
            )
        }
    }

    private func reportFatal(_ error: DolbyVision7ConversionError) {
        let handler = lock.withLock { () -> (@Sendable (DolbyVision7ConversionError) -> Void)? in
            guard !isStopped, !didReportFatalError else { return nil }
            didReportFatalError = true
            return fatalErrorHandler
        }
        guard let handler else { return }
        dolbyVision7Logger.error("Dolby Vision 7 conversion failed: \(String(describing: error), privacy: .public)")
        handler(error)
    }

    private func withSegmentPermit<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        await segmentGate.acquire()
        do {
            let value = try await operation()
            await segmentGate.release()
            return value
        } catch {
            await segmentGate.release()
            throw error
        }
    }

    // MARK: - URLs

    private func proxyURL(_ upstream: URL, route: String, fileExtension: String) -> URL? {
        guard isSameOrigin(upstream), let port = lock.withLock({ port }) else { return nil }
        return URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/\(route)/\(Self.encodedUpstream(upstream)).\(fileExtension)")
    }

    /// Decodes a path component back to its server URL; nil (403) for
    /// garbage or anything off the master playlist's origin.
    private func upstreamURL(_ component: String, fileExtension: String) -> URL? {
        let suffix = "." + fileExtension
        guard component.hasSuffix(suffix),
              let url = Self.decodedUpstream(String(component.dropLast(suffix.count))),
              isSameOrigin(url) else {
            return nil
        }
        return url
    }

    private func isSameOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == upstreamMasterURL.scheme?.lowercased()
            && url.host?.lowercased() == upstreamMasterURL.host?.lowercased()
            && Self.effectivePort(of: url) == Self.effectivePort(of: upstreamMasterURL)
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    static func encodedUpstream(_ url: URL) -> String {
        Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodedUpstream(_ component: String) -> URL? {
        var base64 = component
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return URL(string: string)
    }

    private static func firstVariantURL(in master: String, baseURL: URL) -> URL? {
        var followsStreamInf = false
        for rawLine in master.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                followsStreamInf = true
            } else if followsStreamInf, !line.isEmpty, !line.hasPrefix("#") {
                return URL(string: line, relativeTo: baseURL)?.absoluteURL
            }
        }
        return nil
    }

    private static func conversionError(_ error: any Error) -> DolbyVision7ConversionError {
        if let error = error as? DolbyVision7ConversionError { return error }
        if error is CancellationError { return .proxyUnavailable("stopped") }
        return .proxyUnavailable(error.localizedDescription)
    }
}

/// Caps how many segments are buffered and converted at once.
private actor HLSProxySegmentGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        guard active >= limit else {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the slot straight to the next waiter, if any.
    func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
