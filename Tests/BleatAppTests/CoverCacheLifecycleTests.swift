import BleatCore
import CryptoKit
import MediaPlayer
import XCTest

@testable import Bleat

#if os(iOS)
    import UIKit

    // Network delivery is controlled by continuations. The three-second budgets
    // bound admission failures, not image ordering or the correctness assertion.
    @MainActor
    final class CoverCacheLifecycleTests: XCTestCase {
        private let account = AccountID(rawValue: "cover-lifecycle-a")
        private let otherAccount = AccountID(rawValue: "cover-lifecycle-b")

        private func url(
            item: String = "item", size: Int = 200, timestamp: Int = 1
        ) throws -> URL {
            try XCTUnwrap(
                URL(
                    string:
                        "https://books.example/prefix/api/items/\(item)/cover?width=\(size)&height=\(size)&format=jpeg&ts=\(timestamp)"
                ))
        }

        private func image(_ edge: CGFloat) throws -> Data {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return try XCTUnwrap(
                UIGraphicsImageRenderer(
                    size: CGSize(width: edge, height: edge), format: format
                ).image { context in
                    UIColor.red.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
                }.pngData())
        }

        private func root() -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "cover-lifecycle-\(UUID().uuidString)", isDirectory: true)
        }

        func
            testColdStartRevalidatesBeforeReturningAndPersistsUnchangedTimestampReplacement()
            async throws
        {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = try url()
            let old = try image(2)
            let fresh = try image(3)
            let seed = BookCoverImageLoader(
                cacheRoot: root,
                fetch: { request in try response(old, request) })
            _ = await seed.image(for: url, accountID: account)

            let entered = expectation(
                description:
                    "cold process requests server before displaying disk bytes")
            let gate = CoverDeliveryGate(entered: entered)
            let cold = BookCoverImageLoader(
                cacheRoot: root, fetch: { try await gate.fetch($0) })
            var returned = false
            let online = Task {
                let result = await cold.image(for: url, accountID: account)
                returned = true
                return result
            }
            await fulfillment(of: [entered], timeout: 3)
            XCTAssertFalse(returned)
            let offlineWhileValidating = await cold.image(
                for: url, accountID: account, policy: .cacheOnly)
            XCTAssertEqual(offlineWhileValidating?.size.width, 2)
            try await gate.release(data: fresh)
            let result = await online.value
            XCTAssertEqual(result?.size.width, 3)

            let restarted = BookCoverImageLoader(
                cacheRoot: root,
                fetch: { _ in throw URLError(.notConnectedToInternet) })
            let restored = await restarted.image(
                for: url, accountID: account, policy: .cacheOnly)
            XCTAssertEqual(restored?.size.width, 3)
            // Saved download metadata can carry an older timestamp. It must use
            // the latest canonical variant, never resurrect a timestamp bucket.
            let olderMetadata = try self.url(timestamp: 0)
            let downloaded = await restarted.image(
                for: olderMetadata, accountID: account, policy: .cacheOnly)
            XCTAssertEqual(downloaded?.size.width, 3)
            let failedOnline = await restarted.image(
                for: url, accountID: account)
            XCTAssertEqual(failedOnline?.size.width, 3)
        }

        func
            testConfirmedReplacementInvalidatesEveryVariantAndRejectsLateResponse()
            async throws
        {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            let small = try url()
            let large = try url(size: 600)
            let unrelated = try url(item: "other")
            let old = try image(2)
            let fresh = try image(3)
            let seed = BookCoverImageLoader(
                cacheRoot: root,
                fetch: { request in try response(old, request) })
            for url in [small, large, unrelated] {
                _ = await seed.image(for: url, accountID: account)
            }
            _ = await seed.image(for: small, accountID: otherAccount)

            let entered = expectation(description: "old request admitted")
            let gate = CoverDeliveryGate(entered: entered)
            let loader = BookCoverImageLoader(
                cacheRoot: root, fetch: { try await gate.fetch($0) })
            let stale = Task {
                await loader.image(for: small, accountID: account)
            }
            await fulfillment(of: [entered], timeout: 3)
            await loader.invalidate(for: large, accountID: account)
            let replacement = BookCoverImageLoader(
                cacheRoot: root,
                fetch: { request in try response(fresh, request) })
            _ = await replacement.image(for: small, accountID: account)
            // Deliberately ignore cancellation and complete the retired request.
            try await gate.release(data: old)
            let rejected = await stale.value
            XCTAssertNil(rejected)
            let restarted = BookCoverImageLoader(
                cacheRoot: root,
                fetch: { _ in throw URLError(.notConnectedToInternet) })
            let current = await restarted.image(
                for: small, accountID: account, policy: .cacheOnly)
            let retiredVariant = await restarted.image(
                for: large, accountID: account, policy: .cacheOnly)
            let otherItem = await restarted.image(
                for: unrelated, accountID: account, policy: .cacheOnly)
            let otherOwner = await restarted.image(
                for: small, accountID: otherAccount, policy: .cacheOnly)
            XCTAssertEqual(current?.size.width, 3)
            XCTAssertNil(retiredVariant)
            XCTAssertEqual(otherItem?.size.width, 2)
            XCTAssertEqual(otherOwner?.size.width, 2)
        }

        func testRefreshCoalescesAndAccountRemovalCannotBeRepopulated()
            async throws
        {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = try url()
            let data = try image(3)
            let entered = expectation(description: "first request admitted")
            let joined = expectation(
                description: "second caller joined owned request")
            let gate = CoverDeliveryGate(entered: entered)
            let loader = BookCoverImageLoader(
                observe: { event in
                    if case .joined = event { joined.fulfill() }
                }, cacheRoot: root, fetch: { try await gate.fetch($0) })
            let first = Task {
                await loader.image(for: url, accountID: account)
            }
            await fulfillment(of: [entered], timeout: 3)
            let second = Task {
                await loader.image(for: url, accountID: account)
            }
            await fulfillment(of: [joined], timeout: 3)
            await loader.removeAll(for: account)
            try await gate.release(data: data)
            let results = await (first.value, second.value)
            XCTAssertNil(results.0)
            XCTAssertNil(results.1)
            let count = await gate.count
            XCTAssertEqual(count, 1)
            let cached = await loader.image(
                for: url, accountID: account, policy: .cacheOnly)
            XCTAssertNil(cached)
            let restarted = BookCoverImageLoader(
                cacheRoot: root,
                fetch: { _ in throw URLError(.notConnectedToInternet) })
            let disk = await restarted.image(
                for: url, accountID: account, policy: .cacheOnly)
            XCTAssertNil(disk)
        }

        func
            testExternalRefreshRetiresVariantsAndChangedTimestampCannotReuseObsoleteBytes()
            async throws
        {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            let small = try url()
            let large = try url(size: 600)
            let old = try image(2)
            let fresh = try image(3)
            let fetcher = CoverMutableResponse(data: old)
            let loader = BookCoverImageLoader(
                cacheRoot: root, fetch: { try await fetcher.fetch($0) })
            _ = await loader.image(for: small, accountID: account)
            _ = await loader.image(for: large, accountID: account)
            await fetcher.set(fresh)
            await loader.revalidate(for: account)
            let refreshed = await loader.image(for: small, accountID: account)
            XCTAssertEqual(refreshed?.size.width, 3)
            let obsolete = await loader.image(
                for: large, accountID: account, policy: .cacheOnly)
            XCTAssertNil(obsolete)
            let newer = try url(timestamp: 2)
            let unavailable = await loader.image(
                for: newer, accountID: account, policy: .cacheOnly)
            XCTAssertNil(unavailable)
            let updated = await loader.image(for: newer, accountID: account)
            XCTAssertEqual(updated?.size.width, 3)
            let older = await loader.image(
                for: small, accountID: account, policy: .cacheOnly)
            XCTAssertEqual(older?.size.width, 3)
        }

        func testCoalescedRefreshReturnsCommittedReplacementToEveryWaiter()
            async throws
        {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = try url()
            let old = try image(2)
            let fresh = try image(3)
            let seed = BookCoverImageLoader(
                cacheRoot: root,
                fetch: { request in try response(old, request) })
            _ = await seed.image(for: url, accountID: account)
            let entered = expectation(description: "revalidation admitted")
            let joined = expectation(description: "second revalidation joined")
            let gate = CoverDeliveryGate(entered: entered)
            let loader = BookCoverImageLoader(
                observe: { event in
                    if case .joined = event { joined.fulfill() }
                }, cacheRoot: root, fetch: { try await gate.fetch($0) })
            let first = Task {
                await loader.image(for: url, accountID: account)
            }
            await fulfillment(of: [entered], timeout: 3)
            let second = Task {
                await loader.image(for: url, accountID: account)
            }
            await fulfillment(of: [joined], timeout: 3)
            try await gate.release(data: fresh)
            let results = await (first.value, second.value)
            XCTAssertEqual(results.0?.size.width, 3)
            XCTAssertEqual(results.1?.size.width, 3)
            let cached = await loader.image(for: url, accountID: account)
            XCTAssertEqual(cached?.size.width, 3)
            let count = await gate.count
            XCTAssertEqual(count, 1)
        }

        func testNewTimestampRetiresOlderVariantInFlight() async throws {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            let oldURL = try url()
            let newURL = try url(size: 600, timestamp: 2)
            let old = try image(2)
            let fresh = try image(3)
            let entered = expectation(description: "old timestamp request held")
            let gate = CoverDeliveryGate(entered: entered)
            let loader = BookCoverImageLoader(
                cacheRoot: root,
                fetch: { request in
                    if request.url == oldURL {
                        return try await gate.fetch(request)
                    }
                    return try response(fresh, request)
                })
            let pending = Task {
                await loader.image(for: oldURL, accountID: account)
            }
            await fulfillment(of: [entered], timeout: 3)
            let newer = await loader.image(for: newURL, accountID: account)
            XCTAssertEqual(newer?.size.width, 3)
            try await gate.release(data: old)
            let obsolete = await pending.value
            XCTAssertNil(obsolete)
            let cached = await loader.image(
                for: oldURL, accountID: account, policy: .cacheOnly)
            XCTAssertNil(cached)
            let withOlderMetadata = await loader.image(
                for: oldURL, accountID: account)
            XCTAssertEqual(withOlderMetadata?.size.width, 3)
            let count = await gate.count
            XCTAssertEqual(
                count, 1, "old metadata must request the current timestamp")
        }

        func
            testLegacyOfflineArtworkSurvivesUpgradeButCannotResurrectAfterInvalidation()
            async throws
        {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = try url()
            let data = try image(2)
            func hash(_ text: String) -> String {
                SHA256.hash(data: Data(text.utf8)).map {
                    String(format: "%02x", $0)
                }.joined()
            }
            let directory = root.appendingPathComponent(
                hash(account.rawValue), isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(
                to: directory.appendingPathComponent(hash(url.absoluteString)),
                options: .atomic)
            let large = try self.url(size: 600)
            try data.write(
                to: directory.appendingPathComponent(
                    hash(large.absoluteString)), options: .atomic)
            let loader = BookCoverImageLoader(
                cacheRoot: root,
                fetch: { _ in throw URLError(.notConnectedToInternet) })
            let legacy = await loader.image(
                for: url, accountID: account, policy: .cacheOnly)
            XCTAssertEqual(legacy?.size.width, 2)
            let validator = BookCoverImageLoader(
                cacheRoot: root,
                fetch: { request in try response(data, request) })
            _ = await validator.image(for: url, accountID: account)
            let unchangedSibling = await validator.image(
                for: large, accountID: account, policy: .cacheOnly)
            XCTAssertEqual(unchangedSibling?.size.width, 2)
            await loader.invalidate(for: url, accountID: account)
            let restarted = BookCoverImageLoader(
                cacheRoot: root,
                fetch: { _ in throw URLError(.notConnectedToInternet) })
            let obsolete = await restarted.image(
                for: url, accountID: account, policy: .cacheOnly)
            XCTAssertNil(obsolete)
        }

        func
            testSystemArtworkRevalidatesSameURLAfterUnrelatedAccountNotification()
            async throws
        {
            let url = try url(size: 600)
            let old = try image(2)
            let fresh = try image(3)
            let fetcher = CoverMutableResponse(data: old)
            let loader = BookCoverImageLoader(
                diskCapacity: 0, fetch: { try await fetcher.fetch($0) })
            let publisher = CoverArtworkPublisher()
            let initial = expectation(
                description: "initial system artwork published")
            publisher.didPublish = { artwork in
                if artwork?.image(at: CGSize(width: 1, height: 1))?.size.width
                    == 2
                {
                    initial.fulfill()
                }
            }
            let coordinator = NowPlayingCoordinator(
                infoCenter: publisher, coverLoader: loader,
                registersRemoteCommands: false)
            defer { coordinator.clear() }
            let snapshot = NowPlayingSnapshot(
                accountID: account, itemID: LibraryItemID(rawValue: "item"),
                title: "Fixture", author: "", narrator: "", coverURL: url,
                coverLoadPolicy: .allowNetwork,
                currentTime: 42, duration: 100, rate: 1, isPlaying: false,
                isPlaybackRequested: false,
                isPlaybackAvailable: true, canPerformPreviousCommand: false,
                canPerformNextCommand: false,
                currentChapterIndex: nil, currentChapterTitle: nil,
                chapterCount: 0)
            coordinator.publish(snapshot)
            await fulfillment(of: [initial], timeout: 3)
            let unrelated = expectation(
                description: "unrelated observation delivered and rearmed")
            publisher.didPublish = { artwork in
                if artwork?.image(at: CGSize(width: 1, height: 1))?.size.width
                    == 2
                {
                    unrelated.fulfill()
                }
            }
            BookCoverRefresh.shared.refresh(accountID: otherAccount)
            await fulfillment(of: [unrelated], timeout: 3)
            await fetcher.set(fresh)
            await loader.revalidate(for: account)
            let replacement = expectation(
                description: "same-URL system artwork replaced")
            publisher.didPublish = { artwork in
                if artwork?.image(at: CGSize(width: 1, height: 1))?.size.width
                    == 3
                {
                    replacement.fulfill()
                }
            }
            BookCoverRefresh.shared.refresh(accountID: account)
            await fulfillment(of: [replacement], timeout: 3)
            let artwork =
                publisher.nowPlayingInfo?[MPMediaItemPropertyArtwork]
                as? MPMediaItemArtwork
            XCTAssertEqual(
                artwork?.image(at: CGSize(width: 1, height: 1))?.size.width, 3)
            XCTAssertEqual(
                publisher.nowPlayingInfo?[
                    MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 42)
            XCTAssertEqual(publisher.playbackState, .paused)
        }

        func testCorruptVariantRecoversAndTemporaryWriteIsNeverRead()
            async throws
        {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = try url()
            let data = try image(3)
            let loader = BookCoverImageLoader(
                cacheRoot: root,
                fetch: { request in try response(data, request) })
            _ = await loader.image(for: url, accountID: account)
            let files = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            for file in files.allObjects.compactMap({ $0 as? URL })
            where file.lastPathComponent != ".revision" {
                if (try file.resourceValues(forKeys: [.isRegularFileKey]))
                    .isRegularFile == true
                {
                    try Data("interrupted/corrupt".utf8).write(to: file)
                    try data.write(
                        to: file.deletingLastPathComponent()
                            .appendingPathComponent(".uncommitted"))
                }
            }
            let restarted = BookCoverImageLoader(
                cacheRoot: root,
                fetch: { request in try response(data, request) })
            let corrupt = await restarted.image(
                for: url, accountID: account, policy: .cacheOnly)
            XCTAssertNil(corrupt)
            let recovered = await restarted.image(for: url, accountID: account)
            XCTAssertEqual(recovered?.size.width, 3)
            // Model interruption after the new revision is durably published
            // but before the matching variant payload is replaced. The valid
            // older bytes must not be returned through old downloaded metadata.
            let persisted = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: nil))
            for file in persisted.allObjects.compactMap({ $0 as? URL })
            where file.lastPathComponent == ".revision" {
                try Data("2".utf8).write(to: file, options: .atomic)
            }
            let interrupted = BookCoverImageLoader(
                cacheRoot: root,
                fetch: { request in try response(data, request) })
            let oldPayload = await interrupted.image(
                for: url, accountID: account, policy: .cacheOnly)
            XCTAssertNil(oldPayload)
            let repaired = await interrupted.image(
                for: try self.url(timestamp: 2), accountID: account)
            XCTAssertEqual(repaired?.size.width, 3)
        }
    }

    @MainActor
    private final class CoverArtworkPublisher: NowPlayingInfoPublishing {
        var didPublish: ((MPMediaItemArtwork?) -> Void)?
        var nowPlayingInfo: [String: Any]? {
            didSet {
                didPublish?(
                    nowPlayingInfo?[MPMediaItemPropertyArtwork]
                        as? MPMediaItemArtwork)
            }
        }
        var playbackState: MPNowPlayingPlaybackState = .unknown
    }

    private func response(_ data: Data, _ request: URLRequest) throws -> (
        Data, URLResponse
    ) {
        (
            data,
            try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: 200,
                    httpVersion: nil, headerFields: nil))
        )
    }

    private actor CoverMutableResponse {
        var data: Data
        init(data: Data) { self.data = data }
        func set(_ data: Data) { self.data = data }
        func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
            try response(data, request)
        }
    }

    private actor CoverDeliveryGate {
        let entered: XCTestExpectation
        var pending:
            [(URLRequest, CheckedContinuation<(Data, URLResponse), Error>)] = []
        var request: URLRequest?
        private(set) var count = 0
        init(entered: XCTestExpectation) { self.entered = entered }
        func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
            count += 1
            self.request = request
            return try await withCheckedThrowingContinuation { continuation in
                pending.append((request, continuation))
                entered.fulfill()
            }
        }
        func release(data: Data) throws {
            for (request, continuation) in pending {
                continuation.resume(returning: try response(data, request))
            }
            pending = []
        }
    }
#endif
