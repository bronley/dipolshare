#import <Foundation/Foundation.h>
#import "JSON.h"

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSError *error = nil;
    NSDictionary *message = [NSDictionary dictionaryWithObjectsAndKeys:
        @"iPhone 📡", @"alias", [NSNumber numberWithBool:YES], @"announce",
        [NSArray arrayWithObjects:[NSNumber numberWithInt:0], [NSNull null], nil], @"items", nil];
    NSData *encoded = [JSON dataWithJSONObject:message options:0 error:&error];
    Check(encoded != nil && error == nil, @"encode discovery message");
    NSDictionary *decoded = [JSON JSONObjectWithData:encoded options:0 error:&error];
    Check([decoded isEqualToDictionary:message] && error == nil, @"round trip Unicode, bool and null");

    NSData *invalid = [@"{\"alias\":\"phone\"} trailing" dataUsingEncoding:NSUTF8StringEncoding];
    Check([JSON JSONObjectWithData:invalid options:0 error:&error] == nil,
          @"reject trailing data from a network peer");
    error = nil;
    Check([JSON dataWithJSONObject:@"scalar" options:0 error:&error] == nil && error != nil,
          @"reject top-level scalar");
    error = nil;
    Check([JSON dataWithJSONObject:message options:1 error:&error] == nil && error != nil,
          @"reject unsupported serialization option");
    NSLog(@"PASS: JSONKit adapter");
    [pool drain];
    return 0;
}
