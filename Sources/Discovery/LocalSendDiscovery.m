#import "LocalSendJSON.h"
#import "LocalSendDiscovery.h"
#import "LocalSendIdentityStore.h"
#import "LocalSendDiscoveryProbe.h"
#import "LocalSendDiscoveryMessage.h"
#import "LocalSendReceiver.h"
#import "LocalSendReceiveServer.h"
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
// Same cumulative burst timing as upstream's 100/500/2000 ms delays.
static const NSTimeInterval kAnnouncementTimes[] = {0.1, 0.6, 2.6};
static const NSUInteger LocalSendConcurrentProbeLimit = 4;
static const NSUInteger LocalSendConcurrentSubnetConnectionLimit = 24;
static const NSTimeInterval LocalSendProbeTimeout = 5.0;
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
        _recentlyProbedEndpoints = [[NSMutableDictionary alloc] init];
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
        if (CFSocketSetAddress(_listener, (CFDataRef)bindAddress) != kCFSocketSuccess) {
            CFSocketInvalidate(_listener);
            CFRelease(_listener);
            _listener = NULL;
        } else {
            LocalSendScheduleSocketOnMainRunLoop(_listener);
        }
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
            close(_datagramSocket);
            _datagramSocket = -1;
        }
    }
    if (_datagramSocket >= 0) {
        for (NSDictionary *interface in _interfaces) {
            struct ip_mreq membership;
            memset(&membership, 0, sizeof(membership));
            membership.imr_multiaddr.s_addr = inet_addr(kLocalSendGroup);
            membership.imr_interface.s_addr = inet_addr([[interface objectForKey:@"address"] UTF8String]);
            if (setsockopt(_datagramSocket, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, sizeof(membership)) <
                0) {
                NSLog(@"LocalSend multicast join failed on %@: %s", [interface objectForKey:@"address"],
                      strerror(errno));
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
        }
    }
}

- (void)startDiscoveryTimer {
    _pollTimer = [[NSTimer timerWithTimeInterval:0.1
                                          target:self
                                        selector:@selector(tick:)
                                        userInfo:nil
                                         repeats:YES] retain];
    [[NSRunLoop mainRunLoop] addTimer:_pollTimer forMode:NSRunLoopCommonModes];
    _lastInterfaceCheck = [NSDate timeIntervalSinceReferenceDate];
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
    [self startIncomingListener];
    [self configureLocalDeviceWithFingerprint:fingerprint];
    [self startMulticastDiscovery];
    [self startDiscoveryTimer];
    [self beginScan];
}
- (void)stop {
    _running = NO;
    _generation++;
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
    for (NSNumber *socketDescriptor in _subnetScanSockets) {
        close([socketDescriptor intValue]);
    }
    [_subnetScanSockets removeAllObjects];
    for (LocalSendDiscoveryProbe *probe in _activeProbes) {
        [probe invalidate];
    }
    [_activeProbes removeAllObjects];
    [_pendingDiscoveryProbes removeAllObjects];
    [_pendingSubnetAddresses removeAllObjects];
    [_interfaces release];
    _interfaces = nil;
}
- (void)refresh {
    // Refresh discovery without interrupting incoming file streams.
    if (_running) {
        [self beginScan];
    } else {
        [_identitySetupError release];
        _identitySetupError = nil;
        [self start];
    }
}
- (void)beginScan {
    _scanStart = [NSDate timeIntervalSinceReferenceDate];
    _announcementIndex = 0;
    _scanStarted = NO;
    _foundThisScan = NO;
    [_recentlyProbedEndpoints removeAllObjects];
    // Recheck previously seen addresses immediately, without blanking the list.
    for (NSDictionary *device in [_devicesByFingerprint allValues]) {
        [self enqueueProbe:device];
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
            sendto(_datagramSocket, [data bytes], [data length], 0, (struct sockaddr *)&target,
                   sizeof(target));
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
    NSString *ipAddress = [NSString stringWithUTF8String:inet_ntoa(peer->sin_addr)];
    [_receiveServer acceptSocket:socketDescriptor address:ipAddress];
}
- (void)enqueueProbe:(NSDictionary *)endpoint {
    if (!_running || [_pendingDiscoveryProbes count] >= 256) {
        return;
    }
    NSString *address = [endpoint objectForKey:@"address"];
    if ([self isLocalAddress:address]) {
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%@:%@/%@", address, [endpoint objectForKey:@"port"],
                                               [endpoint objectForKey:@"protocol"]];
    NSDate *lastProbe = [_recentlyProbedEndpoints objectForKey:key];
    if (lastProbe != nil && -[lastProbe timeIntervalSinceNow] < 0.5) {
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
    while (_running && [_activeProbes count] < LocalSendConcurrentProbeLimit &&
           [_pendingDiscoveryProbes count] > 0) {
        NSDictionary *endpoint = [[[_pendingDiscoveryProbes objectAtIndex:0] retain] autorelease];
        [_pendingDiscoveryProbes removeObjectAtIndex:0];
        LocalSendDiscoveryProbe *probe =
            [[[LocalSendDiscoveryProbe alloc] initWithDelegate:self endpoint:endpoint
                                                    generation:_generation] autorelease];
        [_activeProbes addObject:probe];
        [probe startWithIdentity:_identity info:_localInfo];
    }
}
- (void)discoveryProbe:(LocalSendDiscoveryProbe *)probe didCompleteWithMessage:(NSDictionary *)message {
    if ([probe generation] != _generation || ![_activeProbes containsObject:probe]) {
        return;
    }
    NSDictionary *endpoint = [[[probe endpoint] retain] autorelease];
    [probe invalidate];
    [_activeProbes removeObjectIdenticalTo:probe];
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
        NSDictionary *entry = [_subnetScanSockets objectForKey:number];
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
                [self
                    enqueueProbe:[NSDictionary
                                     dictionaryWithObjectsAndKeys:[entry objectForKey:@"address"], @"address",
                                                                  [NSNumber numberWithInt:kLocalSendPort],
                                                                  @"port", @"https", @"protocol",
                                                                  [NSNumber numberWithBool:YES], @"fallback",
                                                                  nil]];
            }
        }
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
    [self startPendingSubnetConnections];
}

- (void)tick:(NSTimer *)timer {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
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
    if (_announcementIndex < 3 && now - _scanStart >= kAnnouncementTimes[_announcementIndex]) {
        [self announce];
        _announcementIndex++;
    }
    if (!_scanStarted && !_foundThisScan && now - _scanStart >= LocalSendMulticastDiscoveryWindow) {
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
    [_recentlyProbedEndpoints release];
    [super dealloc];
}
@end
