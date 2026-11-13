#import <Foundation/Foundation.h>

@interface UpdateManifest : NSObject
+ (NSString *)newerVersionFromData:(NSData *)data installedVersion:(NSString *)installed systemVersion:(NSString *)system;
+ (BOOL)shouldNotifyVersion:(NSString *)version dismissedVersion:(NSString *)dismissed
           remindedVersion:(NSString *)reminded remindAfter:(NSDate *)date now:(NSDate *)now;
@end
