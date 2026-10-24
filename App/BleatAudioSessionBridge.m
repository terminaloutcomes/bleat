#import "BleatAudioSessionBridge.h"
#if TARGET_OS_IOS
#import <AVFAudio/AVFAudio.h>

// Public iOS 27 API declarations for supported older build SDKs. This category
// declares methods only: it adds no implementation, swizzle or runtime cast.
#if __IPHONE_OS_VERSION_MAX_ALLOWED < 270000
@interface AVAudioSession (BleatAsyncActivationDeclarations)
- (void)activateWithOptions:(NSUInteger)options completionHandler:(BleatAudioSessionCompletion)completion;
- (void)deactivateWithOptions:(NSUInteger)options completionHandler:(BleatAudioSessionCompletion)completion;
@end
#endif

void BleatActivateAudioSession(BleatAudioSessionCompletion completion) {
    if (@available(iOS 27.0, *)) {
        [AVAudioSession.sharedInstance activateWithOptions:0 completionHandler:completion];
    } else {
        completion(NO, [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil]);
    }
}

void BleatDeactivateAudioSession(BleatAudioSessionCompletion completion) {
    if (@available(iOS 27.0, *)) {
        NSUInteger options = AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation;
        [AVAudioSession.sharedInstance deactivateWithOptions:options completionHandler:completion];
    } else {
        completion(NO, [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil]);
    }
}
#endif
