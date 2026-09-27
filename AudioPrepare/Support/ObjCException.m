#import "ObjCException.h"

@implementation ObjCException

+ (nullable NSString *)catching:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception.reason ?: exception.name;
    }
}

@end
