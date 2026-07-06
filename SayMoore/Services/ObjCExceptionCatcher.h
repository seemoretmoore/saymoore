#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges Objective-C exceptions into Swift-catchable errors. Some AVFoundation
/// calls (notably `-[AVAudioNode installTapOnBus:...]` on an AirPods aggregate
/// device with mismatched input/output formats) raise an NSException rather than
/// returning an error. An NSException is invisible to Swift `do/catch` and, when
/// it unwinds through a C callback boundary (our CGEvent hotkey tap), aborts the
/// process. Wrap the risky call in `catchException:` so it degrades to a Swift
/// `throw` instead.
@interface ObjCExceptionCatcher : NSObject

/// Runs `tryBlock`. Returns YES if it completed normally; on a caught
/// NSException returns NO and populates `error` (domain `SayMoore.ObjCException`,
/// the exception name/reason in userInfo).
+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))tryBlock
                 error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
