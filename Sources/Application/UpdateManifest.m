#import "UpdateManifest.h"
#import "JSON.h"

static NSArray *VersionComponents(id version) {
    if (![version isKindOfClass:[NSString class]] || [version length] == 0 || [version length] > 39) return nil;
    NSArray *parts = [version componentsSeparatedByString:@"."];
    if ([parts count] > 4) return nil;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    for (NSString *part in parts) {
        if ([part length] == 0 || [part length] > 9 || [part rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    }
    return parts;
}

static NSComparisonResult CompareVersions(NSArray *a, NSArray *b) {
    for (NSUInteger index = 0; index < MAX([a count], [b count]); index++) {
        unsigned long long left = index < [a count] ? [[a objectAtIndex:index] longLongValue] : 0;
        unsigned long long right = index < [b count] ? [[b objectAtIndex:index] longLongValue] : 0;
        if (left != right) return left > right ? NSOrderedDescending : NSOrderedAscending;
    }
    return NSOrderedSame;
}

@implementation UpdateManifest
+ (NSString *)newerVersionFromData:(NSData *)data installedVersion:(NSString *)installed systemVersion:(NSString *)system {
    if ([data length] == 0 || [data length] > 16384) return nil;
    id manifest = [JSON JSONObjectWithData:data options:0 error:NULL];
    if (![manifest isKindOfClass:[NSDictionary class]]) return nil;
    NSString *version = [manifest objectForKey:@"version"];
    NSArray *latest = VersionComponents(version), *current = VersionComponents(installed);
    if (latest == nil || current == nil || CompareVersions(latest, current) != NSOrderedDescending) return nil;
    id minimum = [manifest objectForKey:@"minimumOSVersion"];
    if (minimum != nil) {
        NSArray *required = VersionComponents(minimum), *running = VersionComponents(system);
        if (required == nil || running == nil || CompareVersions(required, running) == NSOrderedDescending) return nil;
    }
    return version;
}

+ (BOOL)shouldNotifyVersion:(NSString *)version dismissedVersion:(NSString *)dismissed
           remindedVersion:(NSString *)reminded remindAfter:(NSDate *)date now:(NSDate *)now {
    NSArray *candidate = VersionComponents(version);
    if (candidate == nil) return NO;
    NSArray *ignored = VersionComponents(dismissed);
    if (ignored != nil && CompareVersions(candidate, ignored) == NSOrderedSame) return NO;
    NSArray *snoozed = VersionComponents(reminded);
    if (snoozed != nil && CompareVersions(candidate, snoozed) == NSOrderedSame &&
        [date isKindOfClass:[NSDate class]] && [date compare:now] == NSOrderedDescending) return NO;
    return YES;
}
@end
