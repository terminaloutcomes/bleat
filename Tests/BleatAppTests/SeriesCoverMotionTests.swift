import CoreGraphics
@testable import Bleat
import XCTest

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
