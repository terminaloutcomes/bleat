import CoreGraphics
import Foundation
import ImageIO

public enum CoverImageProcessingError: Error, Equatable, Sendable {
    case invalidImage
    case encodingFailed
}

public enum CoverImageProcessor {
    public static let maximumDimension: CGFloat = 1_600

    public static func jpegData(
        from sourceData: Data
    ) throws(CoverImageProcessingError) -> Data {
        guard
            let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                ] as CFDictionary
            ),
            image.width > 0,
            image.height > 0
        else {
            throw .invalidImage
        }
        let size = CGSize(
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        guard
            let context = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else {
            throw .encodingFailed
        }
        context.interpolationQuality = .high
        context.setFillColor(
            CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        )
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard
            let rendered = context.makeImage(),
            let data = CFDataCreateMutable(nil, 0),
            let destination = CGImageDestinationCreateWithData(
                data,
                "public.jpeg" as CFString,
                1,
                nil
            )
        else {
            throw .encodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            rendered,
            [kCGImageDestinationLossyCompressionQuality: 0.85]
                as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw .encodingFailed
        }
        return data as Data
    }
}
