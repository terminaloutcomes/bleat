#if canImport(AVFoundation)
    import AVFoundation
    import Foundation

    enum AudioChapterSliceExportFailure: Error, Equatable, Sendable {
        case invalidRange
        case unavailable
        case failed(ChapterTranscriptionDiagnostic)
    }

    struct AudioChapterSliceExporter {
        static func export(
            sourceURL: URL,
            startSeconds: Double,
            durationSeconds: Double?
        ) async throws -> URL {
            guard startSeconds.isFinite, startSeconds >= 0,
                durationSeconds.map({ $0.isFinite && $0 > 0 }) != false
            else {
                throw AudioChapterSliceExportFailure.invalidRange
            }

            let asset = AVURLAsset(url: sourceURL)
            let assetDuration: CMTime
            do {
                assetDuration = try await asset.load(.duration)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AudioChapterSliceExportFailure.failed(
                    ChapterTranscriptionDiagnostic(error)
                )
            }

            let assetDurationSeconds = assetDuration.seconds
            guard assetDurationSeconds.isFinite,
                assetDurationSeconds > 0,
                startSeconds < assetDurationSeconds
            else {
                throw AudioChapterSliceExportFailure.invalidRange
            }

            let remainingSeconds = assetDurationSeconds - startSeconds
            let exportDurationSeconds = min(
                durationSeconds ?? remainingSeconds,
                remainingSeconds
            )
            guard exportDurationSeconds > 0 else {
                throw AudioChapterSliceExportFailure.invalidRange
            }

            guard
                let exporter = AVAssetExportSession(
                    asset: asset,
                    presetName: AVAssetExportPresetPassthrough
                )
            else {
                throw AudioChapterSliceExportFailure.unavailable
            }

            let timescale =
                assetDuration.timescale > 0
                ? assetDuration.timescale
                : CMTimeScale(600)
            exporter.timeRange = CMTimeRange(
                start: CMTime(
                    seconds: startSeconds,
                    preferredTimescale: timescale
                ),
                duration: CMTime(
                    seconds: exportDurationSeconds,
                    preferredTimescale: timescale
                )
            )

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "bleat-transcription-\(UUID().uuidString)"
                )
                .appendingPathExtension("m4a")
            do {
                try await exporter.export(to: outputURL, as: .m4a)
                return outputURL
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: outputURL)
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                throw AudioChapterSliceExportFailure.failed(
                    ChapterTranscriptionDiagnostic(error)
                )
            }
        }
    }
#endif
