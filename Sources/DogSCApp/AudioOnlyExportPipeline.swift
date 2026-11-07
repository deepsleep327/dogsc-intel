import AVFoundation
import Foundation
import RecorderCore

/// Exports the same cut, retimed and per-segment mixed audio heard in the
/// editor without starting the video renderer or encoding a placeholder frame.
final class AudioOnlyExportPipeline: @unchecked Sendable {
    private let session: AVAssetExportSession
    private let outputURL: URL
    private let progressHandler: (@Sendable (Double) -> Void)?

    init(
        media: TimelineCompositionBundle,
        outputURL: URL,
        project: RecorderProject,
        outputRange: MediaTimeRange? = nil,
        progressHandler: (@Sendable (Double) -> Void)?
    ) throws {
        let tracks = [media.systemAudioTrack, media.microphoneAudioTrack]
            .compactMap { $0 }
        guard !tracks.isEmpty else {
            throw VideoExporterError.noAudioToExport
        }
        guard let session = AVAssetExportSession(
            asset: media.primaryComposition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw VideoExporterError.cannotCreateSession
        }
        session.audioMix = TimelineCompositionBuilder.audioMix(
            systemTrack: media.systemAudioTrack,
            systemVolume: project.audio.isSystemMuted
                ? 0 : Float(min(max(project.audio.systemVolume, 0), 1)),
            primarySegmentRanges: media.primarySegmentAudioMixRanges(
                audio: project.audio,
                overrides: project.timeline.primarySegmentAudioOverrides
            ),
            microphoneTrack: media.microphoneAudioTrack,
            microphoneVolume: project.audio.isMicrophoneMuted
                ? 0 : Float(min(max(project.audio.microphoneVolume, 0), 1)),
            requiresTimePitchProcessing: media.requiresAudioTimePitchProcessing,
            timePitchAlgorithm: .spectral
        )
        let range = outputRange ?? MediaTimeRange(
            start: 0,
            duration: media.plan.outputDuration
        )!
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 1_000_000_000),
            duration: CMTime(
                seconds: range.duration,
                preferredTimescale: 1_000_000_000
            )
        )
        session.shouldOptimizeForNetworkUse = true
        self.session = session
        self.outputURL = outputURL
        self.progressHandler = progressHandler
    }

    func run() async throws {
        try Task.checkCancellation()
        progressHandler?(0)
        let progressTask = Task { [self] in
            while !Task.isCancelled {
                progressHandler?(
                    min(max(Double(session.progress), 0), 0.99)
                )
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        defer { progressTask.cancel() }

        do {
            try await withTaskCancellationHandler {
                // macOS 15 SDK compatibility: `export(to:as:)` resolves to the
                // `isolation:` overload that is macOS 15+; gate it and fall
                // back to the classic asynchronous export on macOS 14.
                if #available(macOS 15.0, *) {
                    try await session.export(to: outputURL, as: .m4a)
                } else {
                    try await withCheckedThrowingContinuation {
                        [self] (continuation: CheckedContinuation<Void, Error>) in
                        self.session.exportAsynchronously {
                            switch self.session.status {
                            case .completed:
                                continuation.resume()
                            case .cancelled:
                                continuation.resume(
                                    throwing: VideoExporterError.cancelled
                                )
                            default:
                                let message = self.session.error?.localizedDescription
                                    ?? String(
                                        localized: "导出失败",
                                        comment: "Generic export failure"
                                    )
                                continuation.resume(
                                    throwing: VideoExporterError.exportFailed(message)
                                )
                            }
                        }
                    }
                }
            } onCancel: { [self] in
                session.cancelExport()
            }
        } catch {
            if Task.isCancelled {
                throw VideoExporterError.cancelled
            }
            throw VideoExporterError.exportFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        progressHandler?(1)
    }
}
