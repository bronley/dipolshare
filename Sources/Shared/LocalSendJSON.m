#import "LocalSendJSON.h"
#import "JSONKit.h"

@implementation LocalSendJSON

+ (NSData *)dataWithJSONObject:(id)object options:(NSUInteger)options error:(NSError **)error {
    if (options != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"LocalSendJSON" code:1 userInfo:nil];
        }
        return nil;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        return [(NSDictionary *)object JSONDataWithOptions:JKSerializeOptionNone error:error];
    }
    if ([object isKindOfClass:[NSArray class]]) {
        return [(NSArray *)object JSONDataWithOptions:JKSerializeOptionNone error:error];
    }
    if (error != NULL) {
        *error = [NSError errorWithDomain:@"LocalSendJSON" code:2 userInfo:nil];
    }
    return nil;
}

+ (id)JSONObjectWithData:(NSData *)data options:(NSUInteger)options error:(NSError **)error {
    if (options != 0 || data == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"LocalSendJSON" code:1 userInfo:nil];
        }
        return nil;
    }
    return [data objectFromJSONDataWithParseOptions:JKParseOptionStrict error:error];
}

@end
