import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import BleatCore

final class CoverImageProcessorTests: XCTestCase {
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
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 4)
    }

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

        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(processedData as CFData, nil)
        )
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        )
        XCTAssertEqual(image.width, 1_600)
        XCTAssertEqual(image.height, 800)
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        )
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let tiff =
            properties[kCGImagePropertyTIFFDictionary]
            as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFArtist])
    }

    private func decodedImage(from data: Data) throws -> CGImage {
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(data as CFData, nil)
        )
        return try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        )
    }

    private func jpegData(
        width: Int,
        height: Int,
        properties: [CFString: Any]
    ) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(
            CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        context.fill(
            CGRect(x: 0, y: 0, width: width, height: height)
        )
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(CFDataCreateMutable(nil, 0))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                "public.jpeg" as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
