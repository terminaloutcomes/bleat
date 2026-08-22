import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import Bleat

final class CoverImageProcessorTests: XCTestCase {
    func testJPEGDataAppliesEXIFOrientationBeforeEncoding() throws {
        let sourceData = try jpegData(
            width: 4,
            height: 2,
            orientation: .right
        )

        let processedData = try CoverImageProcessor.jpegData(from: sourceData)

        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(processedData as CFData, nil)
        )
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 4)
    }

    private func jpegData(
        width: Int,
        height: Int,
        orientation: CGImagePropertyOrientation
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
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(CFDataCreateMutable(nil, 0))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
