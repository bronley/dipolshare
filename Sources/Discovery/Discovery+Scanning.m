#import "Discovery+Private.h"
#import "Receiver.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <unistd.h>

static const NSUInteger ConcurrentSubnetConnectionLimit = 8;
static const NSTimeInterval SubnetConnectionTimeout = 0.6;
static const NSTimeInterval MulticastDiscoveryWindow = 3.0;
static const NSTimeInterval ProbeTimeout = 15.0;

@implementation Discovery (Scanning)

- (void)startDiscoveryTimer {
    _pollTimer = [[NSTimer timerWithTimeInterval:0.25
                                          target:self
                                        selector:@selector(tick:)
                                        userInfo:nil
                                         repeats:YES] retain];
    [[NSRunLoop mainRunLoop] addTimer:_pollTimer forMode:NSRunLoopCommonModes];
    _lastInterfaceCheck = [NSDate timeIntervalSinceReferenceDate];
    _lastTickAt = _lastInterfaceCheck;
    _maximumTickGap = 0;
}

- (void)cancelScan {
    _generation++;
    for (DiscoveryProbe *probe in [[_activeProbes copy] autorelease]) {
        [self retireProbe:probe];
    }
    [self reapRetiredProbes];
    [_pendingDiscoveryProbes removeAllObjects];
    for (NSNumber *socketDescriptor in _subnetScanSockets) {
        close([socketDescriptor intValue]);
    }
    [_subnetScanSockets removeAllObjects];
    [_pendingSubnetAddresses removeAllObjects];
    _announcementIndex = 3;
}

- (void)beginScan {
    [self cancelScan];
    _refreshPending = NO;
    _subnetConnectionsAttempted = 0;
    _subnetConnectionsAccepted = 0;
    _scanStart = [NSDate timeIntervalSinceReferenceDate];
    _announcementIndex = 0;
    _scanStarted = NO;
    _foundThisScan = NO;
    [_recentlyProbedEndpoints removeAllObjects];
    [_failedEndpointRetryAfter removeAllObjects];
    [self announceIfDue];
    // Recheck previously seen addresses immediately, without blanking the list.
    for (NSDictionary *device in [_devicesByFingerprint allValues]) {
        [self enqueueProbe:device];
    }
}

- (void)startSubnetScan {
    _scanStarted = YES;
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *interface in _interfaces) {
        uint32_t ipAddress = ntohl(inet_addr([[interface objectForKey:@"address"] UTF8String]));
        uint32_t subnetMask = ntohl(inet_addr([[interface objectForKey:@"mask"] UTF8String]));
        uint32_t network = ipAddress & subnetMask, broadcast = network | ~subnetMask;
        // Upstream bounds fallback to the interface's /24; honor narrower netmasks too.
        uint32_t first = MAX(network + 1, ipAddress & 0xffffff00U),
                 last = MIN(broadcast - 1, (ipAddress & 0xffffff00U) | 255);
        if (subnetMask == 0xffffffffU || broadcast <= network + 1 || first > last) {
            continue;
        }
        for (uint32_t value = first; value <= last; value++) {
            struct in_addr address;
            address.s_addr = htonl(value);
            NSString *host = [NSString stringWithUTF8String:inet_ntoa(address)];
            if (![self isLocalAddress:host] && ![seen containsObject:host]) {
                [seen addObject:host];
                [_pendingSubnetAddresses addObject:host];
            }
        }
    }
}

- (void)checkActiveSubnetConnections {
    for (NSNumber *number in [[[_subnetScanSockets allKeys] copy] autorelease]) {
        int socketDescriptor = [number intValue];
        NSDictionary *entry = [[_subnetScanSockets objectForKey:number] retain];
        fd_set writes;
        FD_ZERO(&writes);
        FD_SET(socketDescriptor, &writes);
        struct timeval timeout = {0, 0};
        BOOL ready = select(socketDescriptor + 1, NULL, &writes, NULL, &timeout) > 0;
        BOOL expired =
            -[[entry objectForKey:@"started"] timeIntervalSinceNow] > SubnetConnectionTimeout;
        if (ready || expired) {
            int error = 0;
            socklen_t length = sizeof(error);
            BOOL connected = ready &&
                             getsockopt(socketDescriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 &&
                             error == 0;
            close(socketDescriptor);
            [_subnetScanSockets removeObjectForKey:number];
            if (connected) {
                _subnetConnectionsAccepted++;
                [self
                    enqueueProbe:[NSDictionary
                                     dictionaryWithObjectsAndKeys:[entry objectForKey:@"address"], @"address",
                                                                  [NSNumber numberWithInt:kLocalSendPort],
                                                                  @"port", @"https", @"protocol",
                                                                  [NSNumber numberWithBool:YES], @"fallback",
                                                                  nil]];
            }
        }
        [entry release];
    }
}

- (void)startPendingSubnetConnections {
    while ([_subnetScanSockets count] < ConcurrentSubnetConnectionLimit &&
           [_pendingSubnetAddresses count] > 0) {
        NSString *host = [[[_pendingSubnetAddresses objectAtIndex:0] retain] autorelease];
        [_pendingSubnetAddresses removeObjectAtIndex:0];
        int socketDescriptor = socket(AF_INET, SOCK_STREAM, 0);
        if (socketDescriptor < 0) {
            break;
        }
        if (socketDescriptor >= FD_SETSIZE) {
            close(socketDescriptor);
            break;
        }
        fcntl(socketDescriptor, F_SETFL, fcntl(socketDescriptor, F_GETFL, 0) | O_NONBLOCK);
        struct sockaddr_in address;
        memset(&address, 0, sizeof(address));
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_port = htons(kLocalSendPort);
        address.sin_addr.s_addr = inet_addr([host UTF8String]);
        int result = connect(socketDescriptor, (struct sockaddr *)&address, sizeof(address));
        _subnetConnectionsAttempted++;
        if (result < 0 && errno != EINPROGRESS) {
            close(socketDescriptor);
            continue;
        }
        [_subnetScanSockets
            setObject:[NSDictionary
                          dictionaryWithObjectsAndKeys:host, @"address", [NSDate date], @"started", nil]
               forKey:[NSNumber numberWithInt:socketDescriptor]];
    }
}

- (void)advanceSubnetScan {
    [self checkActiveSubnetConnections];
    if ([_activeProbes count] == 0 && [_retiringProbes count] == 0 &&
        [_pendingDiscoveryProbes count] == 0) {
        [self startPendingSubnetConnections];
    }
}

- (void)tick:(NSTimer *)timer {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    _maximumTickGap = MAX(_maximumTickGap, now - _lastTickAt);
    _lastTickAt = now;
    if (now - _lastInterfaceCheck >= 2.0) {
        _lastInterfaceCheck = now;
        [[Receiver sharedReceiver] checkTimeouts];
        NSArray *interfaces = DiscoveryNetworkInterfaces();
        if (![_interfaces isEqual:interfaces]) {
            [self stop];
            [_devicesByFingerprint removeAllObjects];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:DiscoveryDevicesDidChangeNotification
                              object:self];
            [self start];
            return;
        }
    }
    [self reapRetiredProbes];
    if (_refreshPending) {
        if (now < _refreshAt) return;
        [self beginScan];
    }
    [self announceIfDue];
    [self startPendingDiscoveryProbes];
    if (!_scanStarted && !_foundThisScan && [_activeProbes count] == 0 &&
        [_retiringProbes count] == 0 &&
        [_pendingDiscoveryProbes count] == 0 &&
        now - _scanStart >= MulticastDiscoveryWindow) {
        [self startSubnetScan];
    }
    for (DiscoveryProbe *probe in [[_activeProbes copy] autorelease]) {
        if (now - [probe startedAt] > ProbeTimeout) {
            [self discoveryProbe:probe didCompleteWithMessage:nil];
        }
    }
    [self advanceSubnetScan];
}
@end
