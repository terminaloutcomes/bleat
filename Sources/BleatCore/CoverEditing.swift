import Foundation

public enum BookCoverUploadError: Error, Equatable, Sendable {
    case invalidItemID
    case emptyImage
    case imageTooLarge
    case requestConstructionFailed(RouteConstructionError)
    case authenticationFailed(AuthenticatedRequestError)
    case requestFailed
    case unexpectedStatus(Int)
    case malformedResponse
    case uploadRejected
}

extension AuthCoordinator {
    public func updateBookCover(
        accountID: AccountID,
        server: NormalizedServerURL,
        itemID: LibraryItemID,
        jpegData: Data
    ) async throws(BookCoverUploadError) {
        guard !itemID.rawValue.isEmpty else {
            throw .invalidItemID
        }
        guard !jpegData.isEmpty else {
            throw .emptyImage
        }
        guard jpegData.count <= 10 * 1_024 * 1_024 else {
            throw .imageTooLarge
        }
        let route = AudiobookshelfRoute.cover(itemID)
        let url: URL
        do {
            url = try AudiobookshelfRouteBuilder(server: server).url(
                for: route
            )
        } catch let error {
            throw .requestConstructionFailed(error)
        }
        let boundary = "Bleat-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.coverMultipartBody(
            jpegData: jpegData,
            boundary: boundary
        )

        let response: HTTPResponse
        do {
            response = try await sendAuthenticated(
                request,
                route: route,
                accountID: accountID,
                server: server
            )
        } catch let error as AuthenticatedRequestError {
            throw .authenticationFailed(error)
        } catch {
            throw .requestFailed
        }
        guard response.statusCode == 200 else {
            throw .unexpectedStatus(response.statusCode)
        }
        let result: CoverUploadResponse
        do {
            result = try JSONDecoder().decode(
                CoverUploadResponse.self,
                from: response.data
            )
        } catch {
            throw .malformedResponse
        }
        guard result.success, !result.cover.isEmpty else {
            throw .uploadRejected
        }
    }

    private static func coverMultipartBody(
        jpegData: Data,
        boundary: String
    ) -> Data {
        var body = Data()
        body.append(
            Data(
                ("--\(boundary)\r\n"
                    + "Content-Disposition: form-data; "
                    + "name=\"cover\"; filename=\"cover.jpg\"\r\n"
                    + "Content-Type: image/jpeg\r\n\r\n").utf8
            )
        )
        body.append(jpegData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

private struct CoverUploadResponse: Decodable {
    let success: Bool
    let cover: String
}
