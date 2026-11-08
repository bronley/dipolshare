#import "Discovery+Private.h"
#import "DiscoveryMessage.h"
#import "Receiver.h"
#import "ReceiveServer.h"
#import "ConnectionActivity.h"
#import <UIKit/UIKit.h>
#import <unistd.h>

NSString *const DiscoveryDevicesDidChangeNotification =
    @"LocalSendDiscoveryDevicesDidChangeNotification";
NSString *const DiscoverySetupDidChangeNotification =
    @"LocalSendDiscoverySetupDidChangeNotification";
NSString *const DiscoveryIdentityDidRegenerateNotification =
    @"LocalSendDiscoveryIdentityDidRegenerateNotification";
static const NSTimeInterval RefreshCoalescingInterval = 0.5;
static NSString *const CustomDeviceNameKey = @"LocalSendCustomDeviceName";

static BOOL IsValidDeviceName(NSString *name) {
    return [name length] > 0 && [name length] <= 64 &&
           [name rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound;
}

@implementation Discovery

+ (NSString *)deviceName {
    NSString *savedName = [[NSUserDefaults standardUserDefaults] stringForKey:CustomDeviceNameKey];
    if (IsValidDeviceName(savedName)) {
        return savedName;
    }
    NSString *systemName = [[[UIDevice currentDevice] name]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([systemName length] > 64) {
        systemName = [systemName substringToIndex:64];
    }
    return IsValidDeviceName(systemName) ? systemName : @"iPhone";
}

+ (BOOL)setDeviceName:(NSString *)name {
    if (![name isKindOfClass:[NSString class]]) {
        return NO;
    }
    NSString *trimmedName = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmedName length] > 0 && !IsValidDeviceName(trimmedName)) {
        return NO;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([trimmedName length] == 0) {
        [defaults removeObjectForKey:CustomDeviceNameKey];
    } else {
        [defaults setObject:trimmedName forKey:CustomDeviceNameKey];
    }
    [defaults synchronize];
    [[Discovery sharedDiscovery] updateDeviceName];
    return YES;
}

+ (Discovery *)sharedDiscovery {
    static Discovery *shared = nil;
    if (shared == nil) {
        shared = [[self alloc] init];
    }
    return shared;
}

- (id)init {
    if ((self = [super init])) {
        _datagramSocket = -1;
        _devicesByFingerprint = [[NSMutableDictionary alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(peerRegistered:)
                                                     name:ReceivePeerDidRegisterNotification
                                                   object:[Receiver sharedReceiver]];
        _subnetScanSockets = [[NSMutableDictionary alloc] init];
        _pendingSubnetAddresses = [[NSMutableArray alloc] init];
        _pendingDiscoveryProbes = [[NSMutableArray alloc] init];
        _activeProbes = [[NSMutableArray alloc] init];
        _retiringProbes = [[NSMutableArray alloc] init];
        _recentlyProbedEndpoints = [[NSMutableDictionary alloc] init];
        _failedEndpointRetryAfter = [[NSMutableDictionary alloc] init];
        _recentProbeFailures = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)configureLocalDeviceWithFingerprint:(NSString *)fingerprint {
    [_localInfo autorelease];
    _localInfo = [[NSDictionary alloc]
        initWithObjectsAndKeys:[Discovery deviceName], @"alias", @"2.2", @"version", @"iPhone", @"deviceModel",
                               @"mobile", @"deviceType", fingerprint, @"fingerprint",
                               [NSNumber numberWithInt:kLocalSendPort], @"port", @"https", @"protocol",
                               [NSNumber numberWithBool:NO], @"download", nil];

    [[Receiver sharedReceiver] setLocalInfo:_localInfo];
    _receiveServer = [[ReceiveServer alloc] initWithIdentity:_identity
                                                             delegate:[Receiver sharedReceiver]];
}

- (void)updateDeviceName {
    if (!_running || _localInfo == nil) {
        return;
    }
    NSMutableDictionary *updatedInfo = [[_localInfo mutableCopy] autorelease];
    [updatedInfo setObject:[Discovery deviceName] forKey:@"alias"];
    [_localInfo release];
    _localInfo = [updatedInfo copy];
    [[Receiver sharedReceiver] setLocalInfo:_localInfo];
    [self announce];
}

- (void)start {
    if (_running || _identitySetupError != nil) {
        return;
    }
    _running = YES;
    if (_identity == NULL) {
        if (!_identityLoading) {
            _identityLoading = YES;
            [NSThread detachNewThreadSelector:@selector(loadIdentityInBackground)
                                     toTarget:self
                                   withObject:nil];
        }
        return;
    }
    [self finishStartingWithFingerprint:_identityFingerprint];
}

- (void)finishStartingWithFingerprint:(NSString *)fingerprint {
    if (!_running || fingerprint == nil) {
        [self stop];
        return;
    }
    _interfaces = [DiscoveryNetworkInterfaces() copy];
    _announcementsSent = 0;
    _datagramsSeen = 0;
    _datagramsReceived = 0;
    _incomingConnections = 0;
    _subnetConnectionsAttempted = 0;
    _subnetConnectionsAccepted = 0;
    _probeAttempts = 0;
    _probeSuccesses = 0;
    _probeFailures = 0;
    [_lastProbeError release];
    _lastProbeError = nil;
    [_lastHTTPSProbeError release];
    _lastHTTPSProbeError = nil;
    [_recentProbeFailures removeAllObjects];
    [self startIncomingListener];
    [self configureLocalDeviceWithFingerprint:fingerprint];
    [self startMulticastDiscovery];
    [self startDiscoveryTimer];
    [self beginScan];
}

- (void)stop {
    _running = NO;
    _refreshPending = NO;
    [self cancelScan];
    [_pollTimer invalidate];
    [_pollTimer release];
    _pollTimer = nil;
    if (_udpSourceSocket != NULL) {
        CFSocketInvalidate(_udpSourceSocket);
        CFRelease(_udpSourceSocket);
        _udpSourceSocket = NULL;
    } else if (_datagramSocket >= 0) {
        close(_datagramSocket);
    }
    _datagramSocket = -1;
    if (_listener != NULL) {
        CFSocketInvalidate(_listener);
        CFRelease(_listener);
        _listener = NULL;
    }
    [[Receiver sharedReceiver] stop];
    [_receiveServer invalidate];
    [_receiveServer release];
    _receiveServer = nil;
    [_failedEndpointRetryAfter removeAllObjects];
    [_interfaces release];
    _interfaces = nil;
}

- (void)refresh {
    // Refresh discovery without interrupting incoming file streams.
    if (_running) {
        if (!_refreshPending) {
            [self cancelScan];
            _refreshPending = YES;
            _refreshAt = [NSDate timeIntervalSinceReferenceDate] + RefreshCoalescingInterval;
        }
    } else {
        [_identitySetupError release];
        _identitySetupError = nil;
        [self start];
    }
}

- (BOOL)isLocalAddress:(NSString *)address {
    for (NSDictionary *interface in _interfaces) {
        if ([[interface objectForKey:@"address"] isEqual:address]) {
            return YES;
        }
    }
    return [address hasPrefix:@"127."];
}

- (void)recordMessage:(NSDictionary *)message address:(NSString *)address {
    if (!IsValidDiscoveryMessage(message) || [self isLocalAddress:address] ||
        [[message objectForKey:@"fingerprint"] isEqual:[_localInfo objectForKey:@"fingerprint"]]) {
        return;
    }
    NSString *fingerprint = [message objectForKey:@"fingerprint"];
    NSString *model = [message objectForKey:@"deviceModel"];
    if (![model isKindOfClass:[NSString class]] || [model length] == 0) {
        model = @"LocalSend";
    }
    NSMutableDictionary *device = [NSMutableDictionary
        dictionaryWithObjectsAndKeys:[message objectForKey:@"alias"], @"alias", fingerprint, @"fingerprint",
                                     [message objectForKey:@"port"], @"port",
                                     [message objectForKey:@"protocol"], @"protocol", address, @"address",
                                     model, @"model", nil];
    NSDictionary *previous = [_devicesByFingerprint objectForKey:fingerprint];
    BOOL changed = previous == nil;
    for (NSString *key in device) {
        if (![[device objectForKey:key] isEqual:[previous objectForKey:key]]) {
            changed = YES;
        }
    }
    [device setObject:[NSDate date] forKey:@"lastSeen"];
    if ([_devicesByFingerprint count] >= 256 && previous == nil) {
        return;
    }
    [_devicesByFingerprint setObject:device forKey:fingerprint];
    _foundThisScan = YES;
    if (changed) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:DiscoveryDevicesDidChangeNotification
                          object:self];
    }
}

- (void)peerRegistered:(NSNotification *)notification {
    if (!_running) {
        return;
    }
    [self recordMessage:[[notification userInfo] objectForKey:@"message"]
                address:[[notification userInfo] objectForKey:@"address"]];
}

- (NSArray *)devices {
    return [[_devicesByFingerprint allValues]
        sortedArrayUsingDescriptors:[NSArray arrayWithObjects:[[[NSSortDescriptor alloc]
                                                                  initWithKey:@"alias"
                                                                    ascending:YES
                                                                     selector:@selector
                                                                     (caseInsensitiveCompare:)] autorelease],
                                                              [[[NSSortDescriptor alloc]
                                                                  initWithKey:@"fingerprint"
                                                                    ascending:YES] autorelease],
                                                              nil]];
}

- (NSString *)discoveryDiagnostics {
    NSMutableArray *addresses = [NSMutableArray array];
    for (NSDictionary *interface in _interfaces) {
        [addresses addObject:[interface objectForKey:@"address"]];
    }
    return [NSString stringWithFormat:
        @"Device: %@ / iOS %@\nIPv4 interfaces: %@\nTCP: %@\nUDP: %@\nMulticast joins: %lu/%lu\nAnnouncements sent: %lu\nUDP packets: %lu seen, %lu valid peers\nIncoming TCP: %lu\nSubnet scan: %@, %lu attempted, %lu open\nProbes: %lu started, %lu succeeded, %lu failed\nDiscovery probes: %lu active, %lu cancelling, %lu queued\nMain timer maximum gap: %.1fs%@%@%@\n%@",
        [[UIDevice currentDevice] model], [[UIDevice currentDevice] systemVersion],
        [addresses count] > 0 ? [addresses componentsJoinedByString:@", "] : @"none",
        _listener != NULL ? @"listening" : (_listenerError ?: @"not listening"),
        _datagramSocket >= 0 ? @"listening" : (_multicastError ?: @"not listening"),
        (unsigned long)_multicastJoinCount, (unsigned long)[_interfaces count],
        (unsigned long)_announcementsSent, (unsigned long)_datagramsSeen, (unsigned long)_datagramsReceived,
        (unsigned long)_incomingConnections, _scanStarted ? @"started" : @"pending",
        (unsigned long)_subnetConnectionsAttempted, (unsigned long)_subnetConnectionsAccepted,
        (unsigned long)_probeAttempts,
        (unsigned long)_probeSuccesses, (unsigned long)_probeFailures,
        (unsigned long)[_activeProbes count], (unsigned long)[_retiringProbes count],
        (unsigned long)[_pendingDiscoveryProbes count],
        _maximumTickGap,
        _multicastError != nil && _datagramSocket >= 0 ? [@"\nUDP issue: " stringByAppendingString:_multicastError] : @"",
        _lastHTTPSProbeError != nil ? [@"\nLast HTTPS failure: " stringByAppendingString:_lastHTTPSProbeError] : @"",
        [_recentProbeFailures count] > 0 ?
            [@"\nRecent probe failures:\n" stringByAppendingString:[_recentProbeFailures componentsJoinedByString:@"\n"]] : @"",
        [ConnectionActivity diagnostics]];
}

- (void)dealloc {
    [self stop];
    if (_identity != NULL) {
        CFRelease(_identity);
    }
    [_identityFingerprint release];
    [_identitySetupError release];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_localInfo release];
    [_devicesByFingerprint release];
    [_subnetScanSockets release];
    [_pendingSubnetAddresses release];
    [_pendingDiscoveryProbes release];
    [_activeProbes release];
    [_retiringProbes release];
    [_recentlyProbedEndpoints release];
    [_failedEndpointRetryAfter release];
    [_listenerError release];
    [_multicastError release];
    [_lastProbeError release];
    [_lastHTTPSProbeError release];
    [_recentProbeFailures release];
    [super dealloc];
}
@end
