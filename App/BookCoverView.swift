import BleatCore
import SwiftUI

enum BookCoverURL {
    static func make(
        server: NormalizedServerURL?,
        itemID: LibraryItemID,
        updatedAtMilliseconds: Int64,
        width: Int,
        height: Int
    ) -> URL? {
        guard let server,
            width > 0,
            height > 0
        else {
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

struct BookCoverView: View {
    let url: URL?
    let cornerRadius: CGFloat

    init(
        server: NormalizedServerURL?,
        itemID: LibraryItemID,
        updatedAtMilliseconds: Int64,
        width: Int,
        height: Int,
        cornerRadius: CGFloat = 8
    ) {
        url = BookCoverURL.make(
            server: server,
            itemID: itemID,
            updatedAtMilliseconds: updatedAtMilliseconds,
            width: width,
            height: height
        )
        self.cornerRadius = cornerRadius
    }

    init(url: URL?, cornerRadius: CGFloat = 8) {
        self.url = url
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .empty:
                placeholder
                    .overlay {
                        ProgressView()
                    }
            case .failure:
                placeholder
            @unknown default:
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: "book.closed.fill")
                .font(.title)
                .foregroundStyle(.secondary)
        }
    }
}
