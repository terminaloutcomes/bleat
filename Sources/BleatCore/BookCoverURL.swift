import Foundation

public enum BookCoverURL {
    public static func make(
        server: NormalizedServerURL?,
        itemID: LibraryItemID,
        updatedAtMilliseconds: Int64,
        width: Int,
        height: Int
    ) -> URL? {
        guard let server, width > 0, height > 0 else {
            return nil
        }
        return try? AudiobookshelfRouteBuilder(server: server).url(
            for: .cover(itemID),
            queryItems: [
                URLQueryItem(name: "width", value: String(width)),
                URLQueryItem(name: "height", value: String(height)),
                URLQueryItem(name: "format", value: "jpeg"),
                URLQueryItem(
                    name: "ts",
                    value: String(updatedAtMilliseconds)
                ),
            ]
        )
    }
}
