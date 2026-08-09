import Foundation

#if canImport(Speech)
    import Speech
#endif

public enum SpeechTranscriptionCapability {
    public static var isAvailable: Bool {
        #if canImport(Speech)
            guard
                #available(macOS 26.0,
                iOS 26.0,
                visionOS 26.0,
                *)
            else {
                return false
            }
            return SpeechTranscriber.isAvailable
        #else
            return false
        #endif
    }
}
