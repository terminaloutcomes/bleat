import CoreGraphics
import XCTest

@testable import Bleat

final class SeriesCoverMotionTests: XCTestCase {
    func testDepthAngleClampsDeliberateSwipes() {
        XCTAssertEqual(
            SeriesCoverMotion.depthAngle(
                swipeOffset: CGFloat(40),
                reduceMotion: false
            ),
            2
        )
        XCTAssertEqual(
            SeriesCoverMotion.depthAngle(
                swipeOffset: CGFloat(400),
                reduceMotion: false
            ),
            12
        )
        XCTAssertEqual(
            SeriesCoverMotion.depthAngle(
                swipeOffset: CGFloat(-400),
                reduceMotion: false
            ),
            -12
        )
    }

    func testDepthAngleIsFlatWhenReduceMotionIsEnabled() {
        XCTAssertEqual(
            SeriesCoverMotion.depthAngle(
                swipeOffset: CGFloat(400),
                reduceMotion: true
            ),
            0
        )
    }
}
