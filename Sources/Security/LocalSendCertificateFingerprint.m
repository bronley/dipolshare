#import "LocalSendCertificateFingerprint.h"

static NSString *LocalSendNormalizedFingerprint(NSString *fingerprint) {
    if (![fingerprint isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSMutableString *result = [NSMutableString stringWithCapacity:[fingerprint length]];
    NSUInteger index;
    for (index = 0; index < [fingerprint length]; index++) {
        unichar character = [fingerprint characterAtIndex:index];
        if ((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f') ||
            (character >= 'A' && character <= 'F')) {
            [result appendFormat:@"%C", character];
        }
    }
    return [result uppercaseString];
}

// Discovery can learn a certificate only when no fingerprint was advertised.
// A supplied fingerprint, and every transfer, must match exactly.
BOOL LocalSendPeerFingerprintMatches(NSString *expected, NSString *actual, BOOL discoveryOnly) {
    NSString *normalizedActual = LocalSendNormalizedFingerprint(actual);
    if ([normalizedActual length] != 64) {
        return NO;
    }
    if (discoveryOnly && expected == nil) {
        return YES;
    }
    NSString *normalizedExpected = LocalSendNormalizedFingerprint(expected);
    return [normalizedExpected length] == 64 && [normalizedExpected isEqualToString:normalizedActual];
}
