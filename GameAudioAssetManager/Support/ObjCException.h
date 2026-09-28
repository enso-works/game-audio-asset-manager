#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block and turns an Objective-C exception into a return value. AVAudioEngine throws
/// NSExceptions (e.g. when the output device disappears) that Swift cannot catch.
@interface ObjCException : NSObject
+ (nullable NSString *)catching:(NS_NOESCAPE void (^)(void))block;
@end

NS_ASSUME_NONNULL_END
