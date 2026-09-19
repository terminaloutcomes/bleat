import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import BleatCore

@Suite(.serialized)
final class CoverImageProcessorTests {
    @Test
    func testJPEGDataAppliesEXIFOrientationBeforeEncoding() throws {
        let sourceData = try jpegData(
            width: 4,
            height: 2,
            properties: [
                kCGImagePropertyOrientation:
                    CGImagePropertyOrientation.right.rawValue
            ]
        )

        let processedData = try CoverImageProcessor.jpegData(
            from: sourceData
        )

        let image = try decodedImage(from: processedData)
        #expect(image.width == 2)
        #expect(image.height == 4)
    }

    @Test
    func testJPEGDataBoundsDimensionsAndDropsSourceMetadata() throws {
        let sourceData = try jpegData(
            width: 2_000,
            height: 1_000,
            properties: [
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 27.4698,
                    kCGImagePropertyGPSLongitude: 153.0251,
                ],
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFArtist: "Private fixture author"
                ],
            ]
        )

        let processedData = try CoverImageProcessor.jpegData(
            from: sourceData
        )

        let source = try #require(
            CGImageSourceCreateWithData(processedData as CFData, nil))
        let image = try #require(
            CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1_600)
        #expect(image.height == 800)
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let tiff =
            properties[kCGImagePropertyTIFFDictionary]
            as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFArtist] == nil)
    }

    private func decodedImage(from data: Data) throws -> CGImage {
        let source = try #require(
            CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func jpegData(
        width: Int,
        height: Int,
        properties: [CFString: Any]
    ) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
        context.setFillColor(
            CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        context.fill(
            CGRect(x: 0, y: 0, width: width, height: height)
        )
        let image = try #require(context.makeImage())
        let data = try #require(CFDataCreateMutable(nil, 0))
        let destination = try #require(
            CGImageDestinationCreateWithData(
                data,
                "public.jpeg" as CFString,
                1,
                nil
            ))
        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary
        )
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
