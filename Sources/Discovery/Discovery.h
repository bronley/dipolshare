#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "DiscoveryProbe.h"
#import "IdentityStore.h"

@class ReceiveServer;

extern NSString *const DiscoveryDevicesDidChangeNotification;
extern NSString *const DiscoverySetupDidChangeNotification;
extern NSString *const DiscoveryIdentityDidRegenerateNotification;

@interface Discovery : NSObject {
    int _datagramSocket;
    CFSocketRef _udpSourceSocket;
    CFSocketRef _listener;
    NSTimer *_pollTimer;
    NSMutableDictionary *_devicesByFingerprint;
    ReceiveServer *_receiveServer;
    NSMutableDictionary *_subnetScanSockets;
    NSMutableArray *_pendingSubnetAddresses;
    NSMutableArray *_pendingDiscoveryProbes;
    NSMutableArray *_activeProbes;
    NSMutableArray *_retiringProbes;
    NSMutableDictionary *_recentlyProbedEndpoints;
    NSMutableDictionary *_failedEndpointRetryAfter;
    NSArray *_interfaces;
    NSDictionary *_localInfo;
    SecIdentityRef _identity;
    NSString *_identityFingerprint;
    NSString *_identitySetupError;
    BOOL _identityLoading;
    BOOL _identityRegenerating;
    BOOL _firstSetupInProgress;
    NSUInteger _generation;
    NSUInteger _announcementIndex;
    BOOL _running;
    BOOL _scanStarted;
    BOOL _foundThisScan;
    BOOL _refreshPending;
    NSTimeInterval _refreshAt;
    NSTimeInterval _nextAnnouncementAt;
    NSTimeInterval _scanStart;
    NSTimeInterval _lastInterfaceCheck;
    NSTimeInterval _lastTickAt;
    NSTimeInterval _maximumTickGap;
    NSUInteger _multicastJoinCount;
    NSUInteger _announcementsSent;
    NSUInteger _datagramsSeen;
    NSUInteger _datagramsReceived;
    NSUInteger _incomingConnections;
    NSUInteger _subnetConnectionsAttempted;
    NSUInteger _subnetConnectionsAccepted;
    NSUInteger _probeAttempts;
    NSUInteger _probeSuccesses;
    NSUInteger _probeFailures;
    NSString *_listenerError;
    NSString *_multicastError;
    NSString *_lastProbeError;
    NSString *_lastHTTPSProbeError;
    NSMutableArray *_recentProbeFailures;
}

+ (Discovery *)sharedDiscovery;
+ (NSString *)deviceName;
+ (BOOL)setDeviceName:(NSString *)name;
- (void)start;
- (void)stop;
- (void)refresh;
- (NSArray *)devices;
- (NSString *)discoveryDiagnostics;
@end

@interface Discovery (Identity)
- (BOOL)isFirstSetupInProgress;
- (BOOL)isRegeneratingIdentity;
- (BOOL)regenerateIdentity;
- (CertificateDateStatus)certificateDateStatus;
- (NSString *)identityFingerprint;
- (NSString *)identitySetupError;
@end

@interface Discovery (Network)
- (BOOL)hasLocalNetworkInterface;
@end
