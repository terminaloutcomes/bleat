import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import BleatCore

final class MetadataEditingLiveTests: XCTestCase {
    func testPinnedRootAndPrefixMetadataUpdates() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootURL = environment["BLEAT_LIVE_ROOT_URL"],
            let prefixURL = environment["BLEAT_LIVE_PREFIX_URL"],
            let username = environment["BLEAT_LIVE_USERNAME"],
            let password = environment["BLEAT_LIVE_PASSWORD"]
        else {
            throw XCTSkip(
                "Run scripts/test-live.sh to provide live metadata data"
            )
        }

        for (index, liveURL) in [rootURL, prefixURL].enumerated() {
            try await verifyMetadataUpdate(
                server: secureLiveServerURL(for: liveURL),
                accountID: AccountID(rawValue: "metadata-\(index)"),
                username: username,
                password: password,
                marker: "Bleat live metadata \(index)"
            )
        }
    }

    func testPinnedRootAndPrefixCoverEditingJourney() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootURL = environment["BLEAT_LIVE_ROOT_URL"],
            let prefixURL = environment["BLEAT_LIVE_PREFIX_URL"],
            let username = environment["BLEAT_LIVE_USERNAME"],
            let password = environment["BLEAT_LIVE_PASSWORD"]
        else {
            throw XCTSkip(
                "Run scripts/test-live.sh to provide live cover data"
            )
        }
        let sourceData = try Self.liveCoverSourceData()
        let jpegData = try CoverImageProcessor.jpegData(from: sourceData)
        let processedSource = try XCTUnwrap(
            CGImageSourceCreateWithData(jpegData as CFData, nil)
        )
        XCTAssertEqual(
            CGImageSourceGetType(processedSource) as String?,
            "public.jpeg"
        )
        let processedImage = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(processedSource, 0, nil)
        )
        XCTAssertLessThanOrEqual(
            max(processedImage.width, processedImage.height),
            Int(CoverImageProcessor.maximumDimension)
        )

        for (index, liveURL) in [rootURL, prefixURL].enumerated() {
            try await verifyCoverEditingJourney(
                server: secureLiveServerURL(for: liveURL),
                accountID: AccountID(rawValue: "cover-editing-\(index)"),
                username: username,
                password: password,
                marker: "Bleat live cover \(index)",
                jpegData: jpegData
            )
        }
    }

    private func verifyMetadataUpdate(
        server: NormalizedServerURL,
        accountID: AccountID,
        username: String,
        password: String,
        marker: String
    ) async throws {
        let transport = LocalDockerHTTPTransport()
        let discovered = try await ServerDiscoveryClient(
            transport: transport
        ).discover(server)
        let credentials = LiveCredentialStore()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: credentials
        )
        let authenticated = try await coordinator.login(
            accountID: accountID,
            server: discovered.baseURL,
            username: username,
            password: password
        )
        XCTAssertTrue(authenticated.user.permissions.update)
        let account = try ServerAccount(
            authenticatedAccount: authenticated,
            discoveredServer: discovered
        )
        let api = AudiobookshelfAPI(
            account: account,
            authCoordinator: coordinator
        )
        let libraries = try await api.libraries()
        let library = try XCTUnwrap(
            libraries.value.first {
                $0.name == "Bleat Live Fixtures"
            }
        )
        let page = try await api.libraryItems(
            in: library.id,
            request: try LibraryItemsPageRequest(
                page: 0,
                limit: 1,
                sort: .title
            )
        )
        let item = try XCTUnwrap(page.value.items.first)
        let originalResponse = try await api.bookDetail(
            for: item.id,
            in: library.id
        )
        let original = originalResponse.value
        var draft = BookMetadataDraft(detail: original)
        draft.publisher = marker

        try await coordinator.updateBookMetadata(
            accountID: accountID,
            server: account.server,
            itemID: item.id,
            patch: try BookMetadataPatch(
                baseline: original,
                draft: draft
            )
        )

        let updatedResponse = try await api.bookDetail(
            for: item.id,
            in: library.id
        )
        let updated = updatedResponse.value
        XCTAssertEqual(updated.publisher, marker)

        var restoreDraft = BookMetadataDraft(detail: updated)
        restoreDraft.publisher = original.publisher ?? ""
        try await coordinator.updateBookMetadata(
            accountID: accountID,
            server: account.server,
            itemID: item.id,
            patch: try BookMetadataPatch(
                baseline: updated,
                draft: restoreDraft
            )
        )
    }

    private func verifyCoverEditingJourney(
        server: NormalizedServerURL,
        accountID: AccountID,
        username: String,
        password: String,
        marker: String,
        jpegData: Data
    ) async throws {
        let transport = FirstCoverUploadFailureTransport()
        let discovered = try await ServerDiscoveryClient(
            transport: transport
        ).discover(server)
        let credentials = LiveCredentialStore()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: credentials
        )
        let authenticated = try await coordinator.login(
            accountID: accountID,
            server: discovered.baseURL,
            username: username,
            password: password
        )
        XCTAssertTrue(authenticated.user.permissions.update)
        XCTAssertTrue(authenticated.user.permissions.upload)
        let account = try ServerAccount(
            authenticatedAccount: authenticated,
            discoveredServer: discovered
        )
        let api = AudiobookshelfAPI(
            account: account,
            authCoordinator: coordinator
        )
        let libraries = try await api.libraries()
        let library = try XCTUnwrap(
            libraries.value.first {
                $0.name == "Bleat Live Fixtures"
            }
        )
        let page = try await api.libraryItems(
            in: library.id,
            request: try LibraryItemsPageRequest(
                page: 0,
                limit: 1,
                sort: .title
            )
        )
        let item = try XCTUnwrap(page.value.items.first)
        let original = try await api.bookDetail(
            for: item.id,
            in: library.id
        ).value
        var draft = BookMetadataDraft(detail: original)
        draft.publisher = marker

        try await coordinator.updateBookMetadata(
            accountID: accountID,
            server: account.server,
            itemID: item.id,
            patch: try BookMetadataPatch(
                baseline: original,
                draft: draft
            )
        )
        let metadataUpdated = try await api.bookDetail(
            for: item.id,
            in: library.id
        ).value
        XCTAssertEqual(metadataUpdated.publisher, marker)
        let preUploadCoverSignature = try await coverSignature(
            server: account.server,
            itemID: item.id,
            updatedAtMilliseconds:
                metadataUpdated.updatedAtMilliseconds,
            transport: transport
        )

        do {
            try await coordinator.updateBookCover(
                accountID: accountID,
                server: account.server,
                itemID: item.id,
                jpegData: jpegData
            )
            XCTFail("Expected the injected first cover upload to fail")
        } catch let error {
            XCTAssertEqual(error, .unexpectedStatus(503))
        }
        let failedJourneyEvents = await transport.events().filter {
            ($0.endpoint == DiagnosticEndpoint.metadata.rawValue
                && $0.method == "PATCH")
                || ($0.endpoint == DiagnosticEndpoint.cover.rawValue
                    && $0.method == "POST")
        }
        XCTAssertEqual(
            failedJourneyEvents,
            [
                LiveCoverRequestEvent(
                    endpoint: DiagnosticEndpoint.metadata.rawValue,
                    method: "PATCH"
                ),
                LiveCoverRequestEvent(
                    endpoint: DiagnosticEndpoint.cover.rawValue,
                    method: "POST"
                ),
            ]
        )

        try await coordinator.updateBookCover(
            accountID: accountID,
            server: account.server,
            itemID: item.id,
            jpegData: jpegData
        )
        let coverUpdated = try await api.bookDetail(
            for: item.id,
            in: library.id
        ).value
        XCTAssertGreaterThan(
            coverUpdated.updatedAtMilliseconds,
            metadataUpdated.updatedAtMilliseconds
        )

        let coverURL = try XCTUnwrap(
            BookCoverURL.make(
                server: account.server,
                itemID: item.id,
                updatedAtMilliseconds:
                    coverUpdated.updatedAtMilliseconds,
                width: 320,
                height: 320
            )
        )
        let components = try XCTUnwrap(
            URLComponents(
                url: coverURL,
                resolvingAgainstBaseURL: false
            )
        )
        XCTAssertEqual(
            components.queryItems?.first { $0.name == "ts" }?.value,
            String(coverUpdated.updatedAtMilliseconds)
        )
        XCTAssertTrue(
            components.percentEncodedPath.hasPrefix(
                account.server.url.path == "/"
                    ? "/api/"
                    : "\(account.server.url.path)/api/"
            )
        )
        let coverResponse = try await transport.send(
            TracedHTTPRequest(
                request: URLRequest(url: coverURL),
                endpoint: .cover
            )
        )
        XCTAssertEqual(coverResponse.statusCode, 200)
        let servedSource = try XCTUnwrap(
            CGImageSourceCreateWithData(
                coverResponse.data as CFData,
                nil
            )
        )
        let servedImage = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(servedSource, 0, nil)
        )
        XCTAssertEqual(servedImage.width, 320)
        XCTAssertEqual(servedImage.height, 320)
        let expectedSignature = try Self.imageSignature(jpegData)
        let servedSignature = try Self.imageSignature(coverResponse.data)
        XCTAssertLessThan(
            Self.meanAbsoluteDifference(
                expectedSignature,
                servedSignature
            ),
            18
        )
        if let preUploadCoverSignature {
            XCTAssertGreaterThan(
                Self.meanAbsoluteDifference(
                    preUploadCoverSignature,
                    servedSignature
                ),
                3
            )
        }
    }

    private func coverSignature(
        server: NormalizedServerURL,
        itemID: LibraryItemID,
        updatedAtMilliseconds: Int64,
        transport: FirstCoverUploadFailureTransport
    ) async throws -> [UInt8]? {
        let url = try XCTUnwrap(
            BookCoverURL.make(
                server: server,
                itemID: itemID,
                updatedAtMilliseconds: updatedAtMilliseconds,
                width: 320,
                height: 320
            )
        )
        let response = try await transport.send(
            TracedHTTPRequest(
                request: URLRequest(url: url),
                endpoint: .cover
            )
        )
        guard response.statusCode == 200 else {
            return nil
        }
        return try Self.imageSignature(response.data)
    }

    private static func imageSignature(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(data as CFData, nil)
        )
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        )
        let side = 32
        let bytesPerPixel = 4
        var pixels = [UInt8](
            repeating: 0,
            count: side * side * bytesPerPixel
        )
        let rendered = pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                let context = CGContext(
                    data: baseAddress,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side * bytesPerPixel,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo:
                        CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: side, height: side)
            )
            return true
        }
        guard rendered else {
            throw LiveCoverSignatureError.renderFailed
        }
        return pixels.enumerated().compactMap { index, value in
            index % bytesPerPixel == 3 ? nil : value
        }
    }

    private static func meanAbsoluteDifference(
        _ lhs: [UInt8],
        _ rhs: [UInt8]
    ) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return .infinity
        }
        let total = zip(lhs, rhs).reduce(0.0) { result, pair in
            result + abs(Double(pair.0) - Double(pair.1))
        }
        return total / Double(lhs.count)
    }

    private static func liveCoverSourceData() throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL =
            repositoryRoot
            .appendingPathComponent("TestSupport")
            .appendingPathComponent("ReleaseScreenshots")
            .appendingPathComponent("covers")
            .appendingPathComponent("goat-ops.png")
        return try Data(contentsOf: sourceURL)
    }
}

private enum LiveCoverSignatureError: Error {
    case renderFailed
}

private struct LiveCoverRequestEvent: Equatable, Sendable {
    let endpoint: String
    let method: String
}

private actor FirstCoverUploadFailureTransport: HTTPTransport {
    private let transport = LocalDockerHTTPTransport()
    private var shouldRejectCoverUpload = true
    private var recordedEvents: [LiveCoverRequestEvent] = []

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async throws -> HTTPResponse {
        let method = tracedRequest.request.httpMethod ?? "GET"
        recordedEvents.append(
            LiveCoverRequestEvent(
                endpoint: tracedRequest.endpoint.rawValue,
                method: method
            )
        )
        if tracedRequest.endpoint.rawValue
            == DiagnosticEndpoint.cover.rawValue,
            method == "POST",
            shouldRejectCoverUpload
        {
            shouldRejectCoverUpload = false
            return HTTPResponse(data: Data(), statusCode: 503)
        }
        return try await transport.send(tracedRequest)
    }

    func events() -> [LiveCoverRequestEvent] {
        recordedEvents
    }
}
