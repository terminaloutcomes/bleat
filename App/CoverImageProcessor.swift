import Foundation
import UIKit

enum CoverImageProcessingError: Error, Equatable, Sendable {
    case invalidImage
    case encodingFailed
}

enum CoverImageProcessor {
    static let maximumDimension: CGFloat = 1_600

    static func jpegData(
        from sourceData: Data
    ) throws(CoverImageProcessingError) -> Data {
        guard let image = UIImage(data: sourceData),
            image.size.width > 0,
            image.size.height > 0
        else {
            throw .invalidImage
        }
        let scale = min(
            maximumDimension
                / max(
                    image.size.width,
                    image.size.height
                ),
            1
        )
        let size = CGSize(
            width: max(1, (image.size.width * scale).rounded()),
            height: max(1, (image.size.height * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(
            size: size,
            format: format
        ).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = rendered.jpegData(compressionQuality: 0.85) else {
            throw .encodingFailed
        }
        return data
    }
}
