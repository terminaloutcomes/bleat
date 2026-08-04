import CoreGraphics

enum SeriesCoverMotion {
    static func depthAngle(
        swipeOffset: CGFloat,
        reduceMotion: Bool
    ) -> Double {
        guard !reduceMotion else { return 0 }
        return Double(min(max(swipeOffset / 20, -12), 12))
    }
}
