#import <Foundation/Foundation.h>

@interface LocalSendJSON : NSObject
+ (NSData *)dataWithJSONObject:(id)object options:(NSUInteger)options error:(NSError **)error;
+ (id)JSONObjectWithData:(NSData *)data options:(NSUInteger)options error:(NSError **)error;
@end
