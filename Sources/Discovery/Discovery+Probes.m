#import "Discovery+Private.h"
#import <arpa/inet.h>

static const NSUInteger ConcurrentProbeLimit = 2;
static const NSTimeInterval FailedProbeRetryDelay = 60.0;
static const NSTimeInterval RepeatProbeInterval = 20.0;

@implementation Discovery (Probes)

- (void)retireProbe:(DiscoveryProbe *)probe {
    [probe invalidate];
    if ([probe hasRunningWorker]) [_retiringProbes addObject:probe];
    [_activeProbes removeObjectIdenticalTo:probe];
}

- (void)reapRetiredProbes {
    for (DiscoveryProbe *probe in [[_retiringProbes copy] autorelease]) {
        if (![probe hasRunningWorker]) [_retiringProbes removeObjectIdenticalTo:probe];
    }
}

- (void)enqueueProbe:(NSDictionary *)endpoint {
    if (!_running || [_pendingDiscoveryProbes count] >= 256) {
        return;
    }
    NSString *address = [endpoint objectForKey:@"address"];
    NSNumber *port = [endpoint objectForKey:@"port"];
    NSString *protocol = [endpoint objectForKey:@"protocol"];
    struct in_addr parsedAddress;
    if (![address isKindOfClass:[NSString class]] ||
        inet_pton(AF_INET, [address UTF8String], &parsedAddress) != 1 ||
        ![port isKindOfClass:[NSNumber class]] || [port intValue] < 1 || [port intValue] > 65535 ||
        (![protocol isEqual:@"https"] && ![protocol isEqual:@"http"])) {
        NSLog(@"LocalSend discovery ignored an invalid probe endpoint: %@", endpoint);
        return;
    }
    if ([self isLocalAddress:address]) {
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%@:%@/%@", address, [endpoint objectForKey:@"port"],
                                               [endpoint objectForKey:@"protocol"]];
    NSDate *retryAfter = [_failedEndpointRetryAfter objectForKey:key];
    if (retryAfter != nil && [retryAfter timeIntervalSinceNow] > 0) {
        return;
    }
    NSDate *lastProbe = [_recentlyProbedEndpoints objectForKey:key];
    if (lastProbe != nil && -[lastProbe timeIntervalSinceNow] < RepeatProbeInterval) {
        return;
    }
    for (DiscoveryProbe *probe in _activeProbes) {
        if ([[[probe endpoint] objectForKey:@"address"] isEqual:address] &&
            [[[probe endpoint] objectForKey:@"port"] isEqual:[endpoint objectForKey:@"port"]]) {
            return;
        }
    }
    for (NSDictionary *pending in _pendingDiscoveryProbes) {
        if ([[pending objectForKey:@"address"] isEqual:address] &&
            [[pending objectForKey:@"port"] isEqual:[endpoint objectForKey:@"port"]]) {
            return;
        }
    }
    if ([_recentlyProbedEndpoints count] >= 512) {
        [_recentlyProbedEndpoints removeAllObjects];
    }
    [_recentlyProbedEndpoints setObject:[NSDate date] forKey:key];
    [_pendingDiscoveryProbes addObject:endpoint];
    [self startPendingDiscoveryProbes];
}

- (void)startPendingDiscoveryProbes {
    [self reapRetiredProbes];
    while (_running && !_refreshPending &&
           [_activeProbes count] + [_retiringProbes count] < ConcurrentProbeLimit &&
           [_pendingDiscoveryProbes count] > 0) {
        NSDictionary *endpoint = [[[_pendingDiscoveryProbes objectAtIndex:0] retain] autorelease];
        [_pendingDiscoveryProbes removeObjectAtIndex:0];
        DiscoveryProbe *probe =
            [[[DiscoveryProbe alloc] initWithDelegate:self endpoint:endpoint
                                                    generation:_generation] autorelease];
        [_activeProbes addObject:probe];
        _probeAttempts++;
        [probe startWithIdentity:_identity info:_localInfo];
    }
}

- (void)discoveryProbe:(DiscoveryProbe *)probe didCompleteWithMessage:(NSDictionary *)message {
    if ([probe generation] != _generation || ![_activeProbes containsObject:probe]) {
        return;
    }
    NSDictionary *endpoint = [[[probe endpoint] retain] autorelease];
    NSString *endpointKey = [NSString stringWithFormat:@"%@:%@/%@",
                            [endpoint objectForKey:@"address"], [endpoint objectForKey:@"port"],
                            [endpoint objectForKey:@"protocol"]];
    if (message != nil) {
        _probeSuccesses++;
        [_failedEndpointRetryAfter removeObjectForKey:endpointKey];
    } else {
        _probeFailures++;
        if ([_failedEndpointRetryAfter count] >= 512) {
            [_failedEndpointRetryAfter removeAllObjects];
        }
        [_failedEndpointRetryAfter setObject:[NSDate dateWithTimeIntervalSinceNow:FailedProbeRetryDelay]
                                     forKey:endpointKey];
        [_lastProbeError release];
        _lastProbeError = [[probe failureMessage] copy];
        if (_lastProbeError == nil) {
            _lastProbeError = [@"Registration timed out." copy];
        }
        NSString *failure = [NSString stringWithFormat:@"%@://%@:%@ — %@",
                            [endpoint objectForKey:@"protocol"] ?: @"unknown",
                            [endpoint objectForKey:@"address"] ?: @"unknown",
                            [endpoint objectForKey:@"port"] ?: @"unknown", _lastProbeError];
        if ([[endpoint objectForKey:@"protocol"] isEqual:@"https"]) {
            [_lastHTTPSProbeError release];
            _lastHTTPSProbeError = [failure copy];
        }
        [_recentProbeFailures addObject:failure];
        if ([_recentProbeFailures count] > 6) {
            [_recentProbeFailures removeObjectAtIndex:0];
        }
        NSLog(@"LocalSend discovery probe failed: %@", failure);
    }
    [self retireProbe:probe];
    if (message != nil) {
        [self recordMessage:message address:[endpoint objectForKey:@"address"]];
    } else if ([[endpoint objectForKey:@"fallback"] boolValue] &&
               [[endpoint objectForKey:@"protocol"] isEqual:@"https"]) {
        // Only unknown scan candidates try both schemes. Never downgrade a known HTTPS peer.
        NSMutableDictionary *http = [[endpoint mutableCopy] autorelease];
        [http setObject:@"http" forKey:@"protocol"];
        [self enqueueProbe:http];
    }
    if (message == nil && [endpoint objectForKey:@"lastSeen"] != nil) {
        NSString *fingerprint = [endpoint objectForKey:@"fingerprint"];
        NSDictionary *current = [_devicesByFingerprint objectForKey:fingerprint];
        if ([[current objectForKey:@"lastSeen"] timeIntervalSinceReferenceDate] < _scanStart) {
            [_devicesByFingerprint removeObjectForKey:fingerprint];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:DiscoveryDevicesDidChangeNotification
                              object:self];
        }
    }
    [self startPendingDiscoveryProbes];
}
@end
