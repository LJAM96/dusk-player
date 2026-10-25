import AVFoundation
import Observation
import os
import UIKit

private let scrubPreviewLogger = Logger(subsystem: "com.dusk-player.app", category: "ScrubPreview")

/// Scrub previews decoded on demand from the video file itself, for files
/// Plex has no preview thumbnails (BIF) for. Each request seeks a separate
/// `AVURLAsset` to the nearest keyframe, so a preview costs one keyframe's
/// worth of byte-range reads and one hardware decode, not a playback session.
///
/// Requests are coalesced: one decode is in flight at a time and only the most
/// recent position waits behind it, so a fast swipe never queues a backlog.
/// Positions are quantised into buckets and decoded frames are kept as small
/// JPEGs for the session, so scrubbing back over a stretch is instant.
@MainActor
@Observable
final class ScrubPreviewGenerator {
    /// False once decoding keeps failing (unreadable file, lost connection);
    /// the scrubber then falls back to its plain time readout.
    private(set) var isAvailable = true

    private var frames: [Int: Data] = [:]
    /// The frame decoded last, shown while the frame for a new position is
    /// still on its way — the scrubber never goes blank between frames.
    private var latestFrame: Data?

    @ObservationIgnored private let decoder: ScrubPreviewFrameDecoder
    @ObservationIgnored private let bucketDuration: TimeInterval
    @ObservationIgnored private var pendingBucket: Int?
    @ObservationIgnored private var isDecoding = false
    @ObservationIgnored private var consecutiveFailures = 0

    private static let maxFailures = 3
    /// ~25 KB each, so a full cache stays a few MB on Apple TV.
    private static let maxCachedFrames = 400

    init(url: URL, duration: TimeInterval?) {
        decoder = ScrubPreviewFrameDecoder(url: url)
        // About 400 distinct previews across the runtime, between 2 s and 15 s
        // apart. Finer buckets would mostly land on the same keyframe.
        let runtime = duration.flatMap { $0 > 0 ? $0 : nil } ?? 7200
        bucketDuration = min(max(runtime / 400, 2), 15)
    }

    /// The frame for `position` if it has been decoded, otherwise the last one
    /// decoded (nil before the first frame arrives).
    func imageData(at position: TimeInterval) -> Data? {
        frames[bucket(for: position)] ?? latestFrame
    }

    func requestFrame(at position: TimeInterval) {
        guard isAvailable else { return }
        let bucket = bucket(for: position)
        guard frames[bucket] == nil else { return }
        pendingBucket = bucket
        guard !isDecoding else { return }
        isDecoding = true

        // Weak so a dismissed player stops after at most the decode in flight.
        Task { [weak self, decoder] in
            while let (bucket, time) = self?.takePendingRequest() {
                let result: Result<Data, any Error>
                do {
                    result = .success(try await decoder.frame(at: time))
                } catch {
                    result = .failure(error)
                }
                self?.finish(bucket: bucket, result: result)
            }
        }
    }

    /// Failures no retry fixes: the file or its codec is unreadable on this
    /// device. Anything else (a network hiccup) gets a few more attempts.
    private static func isPermanent(_ error: any Error) -> Bool {
        switch (error as? AVError)?.code {
        case .decodeFailed?, .decoderNotFound?, .fileFormatNotRecognized?, .failedToParse?,
             .operationNotSupportedForAsset?:
            true
        default:
            false
        }
    }

    private func bucket(for position: TimeInterval) -> Int {
        Int(max(0, position) / bucketDuration)
    }

    private func takePendingRequest() -> (Int, TimeInterval)? {
        guard isAvailable, let bucket = pendingBucket else {
            isDecoding = false
            return nil
        }
        pendingBucket = nil
        return (bucket, (Double(bucket) + 0.5) * bucketDuration)
    }

    private func finish(bucket: Int, result: Result<Data, any Error>) {
        switch result {
        case let .success(data):
            consecutiveFailures = 0
            if frames.count >= Self.maxCachedFrames, let evicted = frames.keys.randomElement() {
                frames[evicted] = nil
            }
            frames[bucket] = data
            latestFrame = data
        case let .failure(error):
            consecutiveFailures += 1
            scrubPreviewLogger.debug(
                "Scrub preview decode failed (\(self.consecutiveFailures, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            if consecutiveFailures >= Self.maxFailures || Self.isPermanent(error) {
                isAvailable = false
            }
        }
    }
}

/// Owns the asset and image generator off the main actor. Decodes are
/// serialised by `ScrubPreviewGenerator` (one in flight at a time), and
/// `AVAssetImageGenerator` may be driven from any thread.
private final class ScrubPreviewFrameDecoder: @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    init(url: URL) {
        let asset = AVURLAsset(url: url)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Twice the tvOS popup (240 pt), enough for a 4K Apple TV and for the
        // iPhone's 3x popup. HDR sources come back tone mapped to SDR, which
        // is the generator's default dynamic-range policy.
        generator.maximumSize = CGSize(width: 480, height: 270)
        // The nearest keyframe on either side: no frames after it are decoded,
        // which is what keeps each preview to a single small read.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
    }

    func frame(at seconds: TimeInterval) async throws -> Data {
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.72) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }
}
