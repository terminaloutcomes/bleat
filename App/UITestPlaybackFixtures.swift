import Foundation

enum PlaybackFixtureResource: String, Codable, Equatable, Sendable {
    case hour = "playback-hour"
    case halfHour = "playback-half-hour"
}

enum PlaybackFixtureFailure: Error, Codable, Equatable, Sendable {
    case missingResource(PlaybackFixtureResource)
}

#if DEBUG || BLEAT_UI_TESTING
    struct UITestPlaybackFixtures: Sendable {
        let hour: URL
        let halfHour: URL

        init(bundle: Bundle = .main) throws(PlaybackFixtureFailure) {
            guard
                let hour = bundle.url(
                    forResource: PlaybackFixtureResource.hour.rawValue,
                    withExtension: "m4a", subdirectory: "UIFixtures"
                )
            else {
                throw .missingResource(.hour)
            }
            guard
                let halfHour = bundle.url(
                    forResource: PlaybackFixtureResource.halfHour.rawValue,
                    withExtension: "m4a", subdirectory: "UIFixtures"
                )
            else {
                throw .missingResource(.halfHour)
            }
            self.hour = hour
            self.halfHour = halfHour
        }
    }
#endif
