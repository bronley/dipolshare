#import "LocalSendDiscoveryMessage.h"

BOOL LocalSendIsValidDiscoveryMessage(NSDictionary *message) {
    if (![message isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    id alias = [message objectForKey:@"alias"], fingerprint = [message objectForKey:@"fingerprint"];
    id port = [message objectForKey:@"port"], protocol = [message objectForKey:@"protocol"];
    return [alias isKindOfClass:[NSString class]] && [alias length] > 0 && [alias length] <= 256 &&
           [fingerprint isKindOfClass:[NSString class]] && [fingerprint length] > 0 &&
           [fingerprint length] <= 256 && [port isKindOfClass:[NSNumber class]] && [port intValue] > 0 &&
           [port intValue] <= 65535 && ([protocol isEqual:@"http"] || [protocol isEqual:@"https"]);
}
