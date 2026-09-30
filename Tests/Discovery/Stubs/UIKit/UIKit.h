#import <Foundation/Foundation.h>
@interface UIDevice : NSObject
+ (UIDevice *)currentDevice;
- (NSString *)name;
- (NSString *)model;
- (NSString *)systemVersion;
@end
