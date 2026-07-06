#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))tryBlock
                 error:(NSError * _Nullable * _Nullable)error {
    @try {
        tryBlock();
        return YES;
    }
    @catch (NSException *exception) {
        if (error != NULL) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            if (exception.name) { info[@"ExceptionName"] = exception.name; }
            if (exception.reason) {
                info[NSLocalizedDescriptionKey] = exception.reason;
                info[@"ExceptionReason"] = exception.reason;
            }
            *error = [NSError errorWithDomain:@"SayMoore.ObjCException"
                                         code:1
                                     userInfo:info];
        }
        return NO;
    }
}

@end
