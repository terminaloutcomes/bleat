import AVFoundation
import Foundation

// KVO invokes observers on the thread that changed the property. Keeping this
// factory nonisolated prevents callbacks from inheriting the caller's actor.
enum PlaybackObservation {
    nonisolated static func handler<Object: Sendable, Value>(
        _ onChange: @escaping @MainActor @Sendable (Object) -> Void
    ) -> @Sendable (Object, NSKeyValueObservedChange<Value>) -> Void {
        { object, _ in
            Task { @MainActor in onChange(object) }
        }
    }
}
