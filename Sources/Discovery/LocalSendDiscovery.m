#import "LocalSendJSON.h"
#import "LocalSendDiscovery.h"
#import "LocalSendIdentityStore.h"
#import "LocalSendDiscoveryProbe.h"
#import "LocalSendDiscoveryMessage.h"
#import "LocalSendReceiver.h"
#import "LocalSendReceiveServer.h"
#import "LocalSendConnectionActivity.h"
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

NSString *const LocalSendDiscoveryDevicesDidChangeNotification =
    @"LocalSendDiscoveryDevicesDidChangeNotification";
NSString *const LocalSendDiscoverySetupDidChangeNotification =
    @"LocalSendDiscoverySetupDidChangeNotification";
NSString *const LocalSendDiscoveryIdentityDidRegenerateNotification =
    @"LocalSendDiscoveryIdentityDidRegenerateNotification";
static const unsigned short kLocalSendPort = 53317;
static const char *kLocalSendGroup = "224.0.0.167";
static const NSTimeInterval LocalSendAnnouncementInterval = 5.0;
static const NSTimeInterval LocalSendRefreshCoalescingInterval = 0.5;
static const NSUInteger LocalSendConcurrentProbeLimit = 2;
static const NSUInteger LocalSendConcurrentSubnetConnectionLimit = 8;
static const NSTimeInterval LocalSendProbeTimeout = 15.0;
static const NSTimeInterval LocalSendFailedProbeRetryDelay = 60.0;
static const NSTimeInterval LocalSendRepeatProbeInterval = 20.0;
static const NSTimeInterval LocalSendSubnetConnectionTimeout = 0.6;
static const NSTimeInterval LocalSendMulticastDiscoveryWindow = 3.0;
static NSString *const LocalSendCustomDeviceNameKey = @"LocalSendCustomDeviceName";

static BOOL LocalSendIsValidDeviceName(NSString *name) {
    return [name length] > 0 && [name length] <= 64 &&
           [name rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound;
}

static NSArray *LocalSendAvailableNetworkInterfaces(void) {
    NSMutableArray *result = [NSMutableArray array];
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) {
        return result;
    }
    struct ifaddrs *entry;
    for (entry = interfaces; entry != NULL; entry = entry->ifa_next) {
        if (entry->ifa_addr == NULL || entry->ifa_netmask == NULL || entry->ifa_addr->sa_family != AF_INET ||
            !(entry->ifa_flags & IFF_UP) || !(entry->ifa_flags & IFF_MULTICAST) ||
            (entry->ifa_flags & (IFF_LOOPBACK | IFF_POINTOPOINT)) ||
            strncmp(entry->ifa_name, "pdp_ip", 6) == 0) {
            continue;
        }
        char ipAddress[INET_ADDRSTRLEN], subnetMask[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((struct sockaddr_in *)entry->ifa_addr)->sin_addr, ipAddress, sizeof(ipAddress));
        inet_ntop(AF_INET, &((struct sockaddr_in *)entry->ifa_netmask)->sin_addr, subnetMask,
                  sizeof(subnetMask));
        [result
            addObject:[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithUTF8String:ipAddress],
                                                                 @"address",
                                                                 [NSString stringWithUTF8String:subnetMask],
                                                                 @"mask", nil]];
    }
    freeifaddrs(interfaces);
    return [result sortedArrayUsingDescriptors:[NSArray arrayWithObject:[[[NSSortDescriptor alloc]
                                                                            initWithKey:@"address"
                                                                              ascending:YES] autorelease]]];
}

@class LocalSendIdentityLoadResult;
@interface LocalSendDiscovery ()
- (void)readDatagrams;
- (void)peerRegistered:(NSNotification *)notification;
- (void)acceptSocket:(int)socketDescriptor address:(NSData *)address;
- (void)tick:(NSTimer *)timer;
- (void)beginScan;
- (void)cancelScan;
- (void)retireProbe:(LocalSendDiscoveryProbe *)probe;
- (void)reapRetiredProbes;
- (void)announceIfDue;
- (void)announce;
- (void)updateDeviceName;
- (void)loadIdentityInBackground;
- (void)identityLoaded:(LocalSendIdentityLoadResult *)result;
- (void)firstSetupStarted:(id)unused;
- (void)regenerateIdentityInBackground;
- (void)identityRegenerated:(LocalSendIdentityLoadResult *)result;
- (void)finishStartingWithFingerprint:(NSString *)fingerprint;
- (void)recordMessage:(NSDictionary *)message address:(NSString *)address;
- (void)enqueueProbe:(NSDictionary *)endpoint;
- (void)startPendingDiscoveryProbes;
- (void)discoveryProbe:(LocalSendDiscoveryProbe *)probe didCompleteWithMessage:(NSDictionary *)message;
@end

static void LocalSendHandleDiscoveryDatagram(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address,
                                             const void *data, void *info) {
    [(LocalSendDiscovery *)info readDatagrams];
}
static void LocalSendAcceptIncomingSocket(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address,
                                          const void *data, void *info) {
    [(LocalSendDiscovery *)info acceptSocket:*(const CFSocketNativeHandle *)data address:(NSData *)address];
}
static void LocalSendScheduleSocketOnMainRunLoop(CFSocketRef socket) {
    CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, socket, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);
}

@interface LocalSendIdentityLoadResult : NSObject {
@public
    SecIdentityRef identity;
    NSString *fingerprint;
    NSString *error;
}
@end
@implementation LocalSendIdentityLoadResult
- (void)dealloc {
    if (identity != NULL) {
        CFRelease(identity);
    }
    [fingerprint release];
    [error release];
    [super dealloc];
}
@end

@implementation LocalSendDiscovery
+ (NSString *)deviceName {
    NSString *savedName = [[NSUserDefaults standardUserDefaults] stringForKey:LocalSendCustomDeviceNameKey];
    if (LocalSendIsValidDeviceName(savedName)) {
        return savedName;
    }
    NSString *systemName = [[[UIDevice currentDevice] name]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([systemName length] > 64) {
        systemName = [systemName substringToIndex:64];
    }
    return LocalSendIsValidDeviceName(systemName) ? systemName : @"iPhone";
}
+ (BOOL)setDeviceName:(NSString *)name {
    if (![name isKindOfClass:[NSString class]]) {
        return NO;
    }
    NSString *trimmedName = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmedName length] > 0 && !LocalSendIsValidDeviceName(trimmedName)) {
        return NO;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([trimmedName length] == 0) {
        [defaults removeObjectForKey:LocalSendCustomDeviceNameKey];
    } else {
        [defaults setObject:trimmedName forKey:LocalSendCustomDeviceNameKey];
    }
    [defaults synchronize];
    [[LocalSendDiscovery sharedDiscovery] updateDeviceName];
    return YES;
}
+ (LocalSendDiscovery *)sharedDiscovery {
    static LocalSendDiscovery *shared = nil;
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
                                                     name:LocalSendReceivePeerDidRegisterNotification
                                                   object:[LocalSendReceiver sharedReceiver]];
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
- (void)loadIdentityInBackground {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    LocalSendIdentityLoadResult *result = [[LocalSendIdentityLoadResult alloc] init];
    NSString *fingerprint = nil;
    NSString *error = nil;
    result->identity = [LocalSendIdentityStore copyIdentityWithFingerprint:&fingerprint
                                                                    error:&error
                                                               willCreate:^{
                                                                   [self performSelectorOnMainThread:@selector(firstSetupStarted:)
                                                                                          withObject:nil
                                                                                       waitUntilDone:NO];
                                                               }];
    result->fingerprint = [fingerprint copy];
    result->error = [error copy];
    [self performSelectorOnMainThread:@selector(identityLoaded:) withObject:result waitUntilDone:NO];
    [result release];
    [pool release];
}

- (void)firstSetupStarted:(id)unused {
    _firstSetupInProgress = YES;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:LocalSendDiscoverySetupDidChangeNotification object:self userInfo:nil];
}

- (void)identityLoaded:(LocalSendIdentityLoadResult *)result {
    _identityLoading = NO;
    if (_firstSetupInProgress) {
        _firstSetupInProgress = NO;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:LocalSendDiscoverySetupDidChangeNotification object:self userInfo:nil];
    }
    if (result->identity == NULL || result->fingerprint == nil) {
        [_identitySetupError release];
        _identitySetupError = [(result->error != nil ? result->error : @"Could not create the device identity.") copy];
        NSLog(@"LocalSend discovery identity: %@", result->error);
        [[NSNotificationCenter defaultCenter]
            postNotificationName:LocalSendDiscoverySetupDidChangeNotification object:self userInfo:nil];
        if (_running) {
            [self stop];
        }
        return;
    }
    [_identitySetupError release];
    _identitySetupError = nil;
    if (_identity == NULL) {
        _identity = (SecIdentityRef)CFRetain(result->identity);
    }
    [_identityFingerprint release];
    _identityFingerprint = [result->fingerprint copy];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:LocalSendDiscoverySetupDidChangeNotification object:self userInfo:nil];
    if (_running) {
        [self finishStartingWithFingerprint:_identityFingerprint];
    }
}

- (BOOL)isFirstSetupInProgress {
    return _firstSetupInProgress;
}

- (BOOL)isRegeneratingIdentity {
    return _identityRegenerating;
}

- (LocalSendCertificateDateStatus)certificateDateStatus {
    return [LocalSendIdentityStore certificateDateStatusForIdentity:_identity];
}

- (NSString *)identityFingerprint {
    return _identityFingerprint;
}
- (NSString *)identitySetupError {
    return _identitySetupError;
}

- (BOOL)regenerateIdentity {
    if (_identityLoading || _identityRegenerating) {
        return NO;
    }
    _identityRegenerating = YES;
    [NSThread detachNewThreadSelector:@selector(regenerateIdentityInBackground)
                             toTarget:self
                           withObject:nil];
    return YES;
}

- (void)regenerateIdentityInBackground {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    LocalSendIdentityLoadResult *result = [[LocalSendIdentityLoadResult alloc] init];
    NSString *fingerprint = nil;
    NSString *error = nil;
    result->identity = [LocalSendIdentityStore regenerateIdentityWithFingerprint:&fingerprint error:&error];
    result->fingerprint = [fingerprint copy];
    result->error = [error copy];
    [self performSelectorOnMainThread:@selector(identityRegenerated:) withObject:result waitUntilDone:NO];
    [result release];
    [pool release];
}

- (void)identityRegenerated:(LocalSendIdentityLoadResult *)result {
    _identityRegenerating = NO;
    BOOL succeeded = result->identity != NULL && result->fingerprint != nil;
    if (succeeded) {
        [_identitySetupError release];
        _identitySetupError = nil;
        BOOL shouldRestart = _running;
        [self stop];
        if (_identity != NULL) {
            CFRelease(_identity);
        }
        _identity = (SecIdentityRef)CFRetain(result->identity);
        [_identityFingerprint release];
        _identityFingerprint = [result->fingerprint copy];
        if (shouldRestart) {
            [self start];
        }
    }
    NSDictionary *details = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:succeeded], @"success",
        result->error != nil ? result->error : @"Could not create the new identity.", @"error", nil];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:LocalSendDiscoveryIdentityDidRegenerateNotification
                      object:self
                    userInfo:details];
}

- (void)startIncomingListener {
    [_listenerError release];
    _listenerError = nil;
    CFSocketContext context = {0, self, NULL, NULL, NULL};
    _listener = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP,
                               kCFSocketAcceptCallBack, LocalSendAcceptIncomingSocket, &context);
    int reuse = 1;
    if (_listener != NULL) {
        setsockopt(CFSocketGetNative(_listener), SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        struct sockaddr_in address;
        memset(&address, 0, sizeof(address));
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_port = htons(kLocalSendPort);
        NSData *bindAddress = [NSData dataWithBytes:&address length:sizeof(address)];
        CFSocketError bindResult = CFSocketSetAddress(_listener, (CFDataRef)bindAddress);
        if (bindResult != kCFSocketSuccess) {
            _listenerError = [[NSString stringWithFormat:@"TCP port %u bind failed (%ld).",
                                                        kLocalSendPort, (long)bindResult] copy];
            NSLog(@"LocalSend discovery: %@", _listenerError);
            CFSocketInvalidate(_listener);
            CFRelease(_listener);
            _listener = NULL;
        } else {
            LocalSendScheduleSocketOnMainRunLoop(_listener);
        }
    } else {
        _listenerError = [@"Could not create the TCP listener." copy];
        NSLog(@"LocalSend discovery: %@", _listenerError);
    }
}

- (void)configureLocalDeviceWithFingerprint:(NSString *)fingerprint {
    [_localInfo autorelease];
    _localInfo = [[NSDictionary alloc]
        initWithObjectsAndKeys:[LocalSendDiscovery deviceName], @"alias", @"2.2", @"version", @"iPhone", @"deviceModel",
                               @"mobile", @"deviceType", fingerprint, @"fingerprint",
                               [NSNumber numberWithInt:kLocalSendPort], @"port", @"https", @"protocol",
                               [NSNumber numberWithBool:NO], @"download", nil];

    [[LocalSendReceiver sharedReceiver] setLocalInfo:_localInfo];
    _receiveServer = [[LocalSendReceiveServer alloc] initWithIdentity:_identity
                                                             delegate:[LocalSendReceiver sharedReceiver]];
}

- (void)updateDeviceName {
    if (!_running || _localInfo == nil) {
        return;
    }
    NSMutableDictionary *updatedInfo = [[_localInfo mutableCopy] autorelease];
    [updatedInfo setObject:[LocalSendDiscovery deviceName] forKey:@"alias"];
    [_localInfo release];
    _localInfo = [updatedInfo copy];
    [[LocalSendReceiver sharedReceiver] setLocalInfo:_localInfo];
    [self announce];
}

- (void)startMulticastDiscovery {
    [_multicastError release];
    _multicastError = nil;
    _multicastJoinCount = 0;
    CFSocketContext context = {0, self, NULL, NULL, NULL};
    int reuse = 1;
    _datagramSocket = socket(AF_INET, SOCK_DGRAM, 0);
    if (_datagramSocket >= 0) {
        setsockopt(_datagramSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        setsockopt(_datagramSocket, SOL_SOCKET, SO_REUSEPORT, &reuse, sizeof(reuse));
        struct sockaddr_in address;
        memset(&address, 0, sizeof(address));
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_port = htons(kLocalSendPort);
        if (bind(_datagramSocket, (struct sockaddr *)&address, sizeof(address)) < 0) {
            _multicastError = [[NSString stringWithFormat:@"UDP port %u bind failed: %s.",
                                                         kLocalSendPort, strerror(errno)] copy];
            NSLog(@"LocalSend discovery: %@", _multicastError);
            close(_datagramSocket);
            _datagramSocket = -1;
        }
    } else {
        _multicastError = [[NSString stringWithFormat:@"Could not create UDP socket: %s.",
                                                     strerror(errno)] copy];
        NSLog(@"LocalSend discovery: %@", _multicastError);
    }
    if (_datagramSocket >= 0) {
        for (NSDictionary *interface in _interfaces) {
            struct ip_mreq membership;
            memset(&membership, 0, sizeof(membership));
            membership.imr_multiaddr.s_addr = inet_addr(kLocalSendGroup);
            membership.imr_interface.s_addr = inet_addr([[interface objectForKey:@"address"] UTF8String]);
            if (setsockopt(_datagramSocket, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, sizeof(membership)) <
                0) {
                int socketError = errno;
                NSLog(@"LocalSend multicast join failed on %@: %s", [interface objectForKey:@"address"],
                      strerror(socketError));
                [_multicastError release];
                _multicastError = [[NSString stringWithFormat:@"Multicast join on %@ failed: %s.",
                                      [interface objectForKey:@"address"], strerror(socketError)] copy];
            } else {
                _multicastJoinCount++;
            }
        }
        unsigned char ttl = 1;
        setsockopt(_datagramSocket, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));
        fcntl(_datagramSocket, F_SETFL, fcntl(_datagramSocket, F_GETFL, 0) | O_NONBLOCK);
        _udpSourceSocket =
            CFSocketCreateWithNative(kCFAllocatorDefault, _datagramSocket, kCFSocketReadCallBack,
                                     LocalSendHandleDiscoveryDatagram, &context);
        if (_udpSourceSocket != NULL) {
            LocalSendScheduleSocketOnMainRunLoop(_udpSourceSocket);
        } else {
            [_multicastError release];
            _multicastError = [@"Could not monitor the UDP socket." copy];
            NSLog(@"LocalSend discovery: %@", _multicastError);
            close(_datagramSocket);
            _datagramSocket = -1;
        }
    }
}

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

- (BOOL)hasLocalNetworkInterface {
    return [LocalSendAvailableNetworkInterfaces() count] > 0;
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
    _interfaces = [LocalSendAvailableNetworkInterfaces() copy];
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
    [[LocalSendReceiver sharedReceiver] stop];
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
            _refreshAt = [NSDate timeIntervalSinceReferenceDate] + LocalSendRefreshCoalescingInterval;
        }
    } else {
        [_identitySetupError release];
        _identitySetupError = nil;
        [self start];
    }
}
- (void)retireProbe:(LocalSendDiscoveryProbe *)probe {
    [probe invalidate];
    if ([probe hasRunningWorker]) [_retiringProbes addObject:probe];
    [_activeProbes removeObjectIdenticalTo:probe];
}
- (void)reapRetiredProbes {
    for (LocalSendDiscoveryProbe *probe in [[_retiringProbes copy] autorelease]) {
        if (![probe hasRunningWorker]) [_retiringProbes removeObjectIdenticalTo:probe];
    }
}
- (void)cancelScan {
    _generation++;
    for (LocalSendDiscoveryProbe *probe in [[_activeProbes copy] autorelease]) {
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
- (void)announceIfDue {
    if (_announcementIndex < 3 && [NSDate timeIntervalSinceReferenceDate] >= _nextAnnouncementAt) {
        _nextAnnouncementAt = [NSDate timeIntervalSinceReferenceDate] + LocalSendAnnouncementInterval;
        [self announce];
        _announcementIndex++;
    }
}
- (void)announce {
    if (_datagramSocket < 0 || _listener == NULL) {
        return;
    }
    NSMutableDictionary *message = [[_localInfo mutableCopy] autorelease];
    [message setObject:[NSNumber numberWithBool:YES] forKey:@"announce"];
    NSData *data = [LocalSendJSON dataWithJSONObject:message options:0 error:NULL];
    struct sockaddr_in target;
    memset(&target, 0, sizeof(target));
    target.sin_len = sizeof(target);
    target.sin_family = AF_INET;
    target.sin_port = htons(kLocalSendPort);
    target.sin_addr.s_addr = inet_addr(kLocalSendGroup);
    for (NSDictionary *interface in _interfaces) {
        struct in_addr address;
        address.s_addr = inet_addr([[interface objectForKey:@"address"] UTF8String]);
        if (setsockopt(_datagramSocket, IPPROTO_IP, IP_MULTICAST_IF, &address, sizeof(address)) == 0) {
            if (sendto(_datagramSocket, [data bytes], [data length], 0, (struct sockaddr *)&target,
                       sizeof(target)) >= 0) {
                _announcementsSent++;
            } else {
                [_multicastError release];
                _multicastError = [[NSString stringWithFormat:@"Announcement send failed: %s.", strerror(errno)] copy];
                NSLog(@"LocalSend discovery: %@", _multicastError);
            }
        } else {
            [_multicastError release];
            _multicastError = [[NSString stringWithFormat:@"Multicast interface %@ failed: %s.",
                                 [interface objectForKey:@"address"], strerror(errno)] copy];
            NSLog(@"LocalSend discovery: %@", _multicastError);
        }
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
- (void)readDatagrams {
    // Bound work per callback so a busy LAN cannot starve the UI.
    for (NSUInteger count = 0; count < 64; count++) {
        unsigned char buffer[65536];
        struct sockaddr_in peer;
        socklen_t length = sizeof(peer);
        ssize_t size =
            recvfrom(_datagramSocket, buffer, sizeof(buffer), 0, (struct sockaddr *)&peer, &length);
        if (size < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                [self stop];
                [self start];
            }
            break;
        }
        _datagramsSeen++;
        id message = [LocalSendJSON JSONObjectWithData:[NSData dataWithBytes:buffer length:size]
                                                     options:0
                                                       error:NULL];
        if (!LocalSendIsValidDiscoveryMessage(message)) {
            continue;
        }
        NSString *address = [NSString stringWithUTF8String:inet_ntoa(peer.sin_addr)];
        if ([self isLocalAddress:address] ||
            [[message objectForKey:@"fingerprint"] isEqual:[_localInfo objectForKey:@"fingerprint"]]) {
            continue;
        }
        _datagramsReceived++;
        // UDP is a candidate. Confirm it with /register (and pin advertised TLS certificates).
        NSMutableDictionary *endpoint = [[message mutableCopy] autorelease];
        [endpoint setObject:address forKey:@"address"];
        [self enqueueProbe:endpoint];
    }
}
- (void)recordMessage:(NSDictionary *)message address:(NSString *)address {
    if (!LocalSendIsValidDiscoveryMessage(message) || [self isLocalAddress:address] ||
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
            postNotificationName:LocalSendDiscoveryDevicesDidChangeNotification
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
- (void)acceptSocket:(int)socketDescriptor address:(NSData *)address {
    if (_receiveServer == nil || [address length] < sizeof(struct sockaddr_in)) {
        close(socketDescriptor);
        return;
    }
    const struct sockaddr_in *peer = [address bytes];
    _incomingConnections++;
    NSString *ipAddress = [NSString stringWithUTF8String:inet_ntoa(peer->sin_addr)];
    [_receiveServer acceptSocket:socketDescriptor address:ipAddress];
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
    if (lastProbe != nil && -[lastProbe timeIntervalSinceNow] < LocalSendRepeatProbeInterval) {
        return;
    }
    for (LocalSendDiscoveryProbe *probe in _activeProbes) {
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
           [_activeProbes count] + [_retiringProbes count] < LocalSendConcurrentProbeLimit &&
           [_pendingDiscoveryProbes count] > 0) {
        NSDictionary *endpoint = [[[_pendingDiscoveryProbes objectAtIndex:0] retain] autorelease];
        [_pendingDiscoveryProbes removeObjectAtIndex:0];
        LocalSendDiscoveryProbe *probe =
            [[[LocalSendDiscoveryProbe alloc] initWithDelegate:self endpoint:endpoint
                                                    generation:_generation] autorelease];
        [_activeProbes addObject:probe];
        _probeAttempts++;
        [probe startWithIdentity:_identity info:_localInfo];
    }
}
- (void)discoveryProbe:(LocalSendDiscoveryProbe *)probe didCompleteWithMessage:(NSDictionary *)message {
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
        [_failedEndpointRetryAfter setObject:[NSDate dateWithTimeIntervalSinceNow:LocalSendFailedProbeRetryDelay]
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
                postNotificationName:LocalSendDiscoveryDevicesDidChangeNotification
                              object:self];
        }
    }
    [self startPendingDiscoveryProbes];
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
            -[[entry objectForKey:@"started"] timeIntervalSinceNow] > LocalSendSubnetConnectionTimeout;
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
    while ([_subnetScanSockets count] < LocalSendConcurrentSubnetConnectionLimit &&
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
        [[LocalSendReceiver sharedReceiver] checkTimeouts];
        NSArray *interfaces = LocalSendAvailableNetworkInterfaces();
        if (![_interfaces isEqual:interfaces]) {
            [self stop];
            [_devicesByFingerprint removeAllObjects];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:LocalSendDiscoveryDevicesDidChangeNotification
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
        now - _scanStart >= LocalSendMulticastDiscoveryWindow) {
        [self startSubnetScan];
    }
    for (LocalSendDiscoveryProbe *probe in [[_activeProbes copy] autorelease]) {
        if (now - [probe startedAt] > LocalSendProbeTimeout) {
            [self discoveryProbe:probe didCompleteWithMessage:nil];
        }
    }
    [self advanceSubnetScan];
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
        [LocalSendConnectionActivity diagnostics]];
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
