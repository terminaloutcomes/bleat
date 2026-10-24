#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#if TARGET_OS_IOS
NS_ASSUME_NONNULL_BEGIN
typedef void (^ NS_SWIFT_SENDABLE BleatAudioSessionCompletion)(BOOL succeeded, NSError * _Nullable error);
FOUNDATION_EXPORT void BleatActivateAudioSession(BleatAudioSessionCompletion completion) API_AVAILABLE(ios(27.0));
FOUNDATION_EXPORT void BleatDeactivateAudioSession(BleatAudioSessionCompletion completion) API_AVAILABLE(ios(27.0));
NS_ASSUME_NONNULL_END
#endif
