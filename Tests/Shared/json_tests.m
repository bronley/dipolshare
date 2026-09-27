#import <Foundation/Foundation.h>
#import "LocalSendJSON.h"

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
    NSData *encoded = [LocalSendJSON dataWithJSONObject:message options:0 error:&error];
    Check(encoded != nil && error == nil, @"encode discovery message");
    NSDictionary *decoded = [LocalSendJSON JSONObjectWithData:encoded options:0 error:&error];
    Check([decoded isEqualToDictionary:message] && error == nil, @"round trip Unicode, bool and null");

    NSData *invalid = [@"{\"alias\":\"phone\"} trailing" dataUsingEncoding:NSUTF8StringEncoding];
    Check([LocalSendJSON JSONObjectWithData:invalid options:0 error:&error] == nil,
          @"reject trailing data from a network peer");
    error = nil;
    Check([LocalSendJSON dataWithJSONObject:@"scalar" options:0 error:&error] == nil && error != nil,
          @"reject top-level scalar");
    error = nil;
    Check([LocalSendJSON dataWithJSONObject:message options:1 error:&error] == nil && error != nil,
          @"reject unsupported serialization option");
    NSLog(@"PASS: JSONKit adapter");
    [pool drain];
    return 0;
}
