#if canImport(AVFAudio) && canImport(Speech)
    import AVFAudio
    import Foundation
    import Speech

    public struct SpeechChapterTranscriber: ChapterTranscribing {
        public init() {}

        public func transcribe(
            _ request: ChapterTranscriptionRequest
        ) async throws -> [TranscriptSegment] {
            guard request.chapterStartSeconds.isFinite,
                request.chapterStartSeconds >= 0
            else {
                throw ChapterTranscriptionFailure.invalidChapterStart
            }
            guard request.audioStartSeconds.isFinite,
                request.audioStartSeconds >= 0,
                request.audioDurationSeconds.map({
                    $0.isFinite && $0 > 0
                }) != false
            else {
                throw ChapterTranscriptionFailure.invalidAudioRange
            }

            guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else {
                throw ChapterTranscriptionFailure.operatingSystemUnsupported
            }

            return try await transcribeUsingSpeechTranscriber(request)
        }

        @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
        private func transcribeUsingSpeechTranscriber(
            _ request: ChapterTranscriptionRequest
        ) async throws -> [TranscriptSegment] {
            guard SpeechTranscriber.isAvailable else {
                throw ChapterTranscriptionFailure.unavailableOnDevice
            }

            guard
                let supportedLocale = await SpeechTranscriber.supportedLocale(
                    equivalentTo: request.locale
                )
            else {
                throw ChapterTranscriptionFailure.unsupportedLocale(
                    request.locale.identifier
                )
            }

            let transcriber = SpeechTranscriber(
                locale: supportedLocale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            let modules: [any SpeechModule] = [transcriber]
            try await installAssetsIfNeeded(for: modules)

            let chapterAudioURL: URL
            do {
                chapterAudioURL = try await AudioChapterSliceExporter.export(
                    sourceURL: request.audioFileURL,
                    startSeconds: request.audioStartSeconds,
                    durationSeconds: request.audioDurationSeconds
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch AudioChapterSliceExportFailure.invalidRange {
                throw ChapterTranscriptionFailure.invalidAudioRange
            } catch AudioChapterSliceExportFailure.unavailable {
                throw ChapterTranscriptionFailure.chapterExtractionUnavailable
            } catch AudioChapterSliceExportFailure.failed(let diagnostic) {
                throw ChapterTranscriptionFailure.chapterExtractionFailed(
                    diagnostic
                )
            } catch {
                throw ChapterTranscriptionFailure.chapterExtractionFailed(
                    ChapterTranscriptionDiagnostic(error)
                )
            }
            defer {
                try? FileManager.default.removeItem(at: chapterAudioURL)
            }

            let audioFile: AVAudioFile
            do {
                audioFile = try AVAudioFile(forReading: chapterAudioURL)
            } catch {
                throw ChapterTranscriptionFailure.audioFileUnreadable(
                    request.audioFileURL.lastPathComponent
                )
            }

            let analyzer = SpeechAnalyzer(modules: modules)
            let resultsTask = transcriptResultsTask(
                from: transcriber,
                chapterStartSeconds: request.chapterStartSeconds
            )

            let lastSampleTime: CMTime?
            do {
                lastSampleTime = try await analyzer.analyzeSequence(
                    from: audioFile
                )
                try Task.checkCancellation()
            } catch is CancellationError {
                resultsTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw CancellationError()
            } catch {
                resultsTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw ChapterTranscriptionFailure.analyzerInputFailed(
                    ChapterTranscriptionDiagnostic(error)
                )
            }

            do {
                if let lastSampleTime {
                    try await analyzer.finalizeAndFinish(
                        through: lastSampleTime
                    )
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch is CancellationError {
                resultsTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw CancellationError()
            } catch {
                resultsTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw ChapterTranscriptionFailure.analyzerFinalizationFailed(
                    ChapterTranscriptionDiagnostic(error)
                )
            }

            do {
                let segments = try await resultsTask.value
                return segments.sorted {
                    ($0.startMilliseconds, $0.endMilliseconds)
                        < ($1.startMilliseconds, $1.endMilliseconds)
                }
            } catch is CancellationError {
                await analyzer.cancelAndFinishNow()
                throw CancellationError()
            } catch {
                await analyzer.cancelAndFinishNow()
                throw ChapterTranscriptionFailure.resultStreamFailed(
                    ChapterTranscriptionDiagnostic(error)
                )
            }
        }

        @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
        private func installAssetsIfNeeded(
            for modules: [any SpeechModule]
        ) async throws {
            switch await AssetInventory.status(forModules: modules) {
            case .unsupported:
                throw ChapterTranscriptionFailure.languageAssetsUnavailable
            case .supported, .downloading:
                do {
                    guard
                        let installationRequest =
                            try await AssetInventory
                            .assetInstallationRequest(supporting: modules)
                    else {
                        throw ChapterTranscriptionFailure
                            .languageAssetsUnavailable
                    }
                    try await installationRequest.downloadAndInstall()
                } catch let failure as ChapterTranscriptionFailure {
                    throw failure
                } catch {
                    throw ChapterTranscriptionFailure
                        .languageAssetInstallationFailed
                }
            case .installed:
                break
            @unknown default:
                throw ChapterTranscriptionFailure.languageAssetsUnavailable
            }
        }

        @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
        private func transcriptResultsTask(
            from transcriber: SpeechTranscriber,
            chapterStartSeconds: Double
        ) -> Task<[TranscriptSegment], any Error> {
            Task {
                var segments: [TranscriptSegment] = []
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty,
                        let segment = WholeBookTranscriptTimeline.segment(
                            relativeStartSeconds: result.range.start.seconds,
                            relativeDurationSeconds: result.range.duration
                                .seconds,
                            chapterStartSeconds: chapterStartSeconds,
                            text: text
                        )
                    else {
                        continue
                    }
                    segments.append(segment)
                }
                return segments
            }
        }
    }
#endif
