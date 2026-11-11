#import "Discovery+Private.h"
#import "JSON.h"
#import "DiscoveryMessage.h"
#import "ReceiveServer.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <unistd.h>

const unsigned short kLocalSendPort = 53317;
static const char *kLocalSendGroup = "224.0.0.167";
static const NSTimeInterval AnnouncementInterval = 5.0;

NSArray *DiscoveryNetworkInterfaces(void) {
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

static void HandleDiscoveryDatagram(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address,
                                             const void *data, void *info) {
    [(Discovery *)info readDatagrams];
}
static void AcceptIncomingSocket(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address,
                                          const void *data, void *info) {
    [(Discovery *)info acceptSocket:*(const CFSocketNativeHandle *)data address:(NSData *)address];
}
static void ScheduleSocketOnMainRunLoop(CFSocketRef socket) {
    CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, socket, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);
}

@implementation Discovery (Network)

- (void)startIncomingListener {
    [_listenerError release];
    _listenerError = nil;
    CFSocketContext context = {0, self, NULL, NULL, NULL};
    _listener = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP,
                               kCFSocketAcceptCallBack, AcceptIncomingSocket, &context);
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
            ScheduleSocketOnMainRunLoop(_listener);
        }
    } else {
        _listenerError = [@"Could not create the TCP listener." copy];
        NSLog(@"LocalSend discovery: %@", _listenerError);
    }
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
                                     HandleDiscoveryDatagram, &context);
        if (_udpSourceSocket != NULL) {
            ScheduleSocketOnMainRunLoop(_udpSourceSocket);
        } else {
            [_multicastError release];
            _multicastError = [@"Could not monitor the UDP socket." copy];
            NSLog(@"LocalSend discovery: %@", _multicastError);
            close(_datagramSocket);
            _datagramSocket = -1;
        }
    }
}

- (BOOL)hasLocalNetworkInterface {
    return [DiscoveryNetworkInterfaces() count] > 0;
}

- (void)announceIfDue {
    if (_announcementIndex < 3 && [NSDate timeIntervalSinceReferenceDate] >= _nextAnnouncementAt) {
        _nextAnnouncementAt = [NSDate timeIntervalSinceReferenceDate] + AnnouncementInterval;
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
    NSData *data = [JSON dataWithJSONObject:message options:0 error:NULL];
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
        id message = [JSON JSONObjectWithData:[NSData dataWithBytes:buffer length:size]
                                                     options:0
                                                       error:NULL];
        if (!IsValidDiscoveryMessage(message)) {
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
@end
