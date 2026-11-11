#import <Foundation/Foundation.h>

// iOS 4 fallback
@interface VCardWriter : NSObject
+ (NSData *)dataForContact:(NSDictionary *)contact;
@end
