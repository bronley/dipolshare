#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "LocalSendDiscoveryProbe.h"
#import "LocalSendIdentityStore.h"

@class LocalSendReceiveServer;

extern NSString *const LocalSendDiscoveryDevicesDidChangeNotification;
extern NSString *const LocalSendDiscoverySetupDidChangeNotification;
extern NSString *const LocalSendDiscoveryIdentityDidRegenerateNotification;

@interface LocalSendDiscovery : NSObject <LocalSendDiscoveryProbeDelegate> {
    int _datagramSocket;
    CFSocketRef _udpSourceSocket;
    CFSocketRef _listener;
    NSTimer *_pollTimer;
    NSMutableDictionary *_devicesByFingerprint;
    LocalSendReceiveServer *_receiveServer;
    NSMutableDictionary *_subnetScanSockets;
    NSMutableArray *_pendingSubnetAddresses;
    NSMutableArray *_pendingDiscoveryProbes;
    NSMutableArray *_activeProbes;
    NSMutableDictionary *_recentlyProbedEndpoints;
    NSArray *_interfaces;
    NSDictionary *_localInfo;
    SecIdentityRef _identity;
    NSString *_identityFingerprint;
    BOOL _identityLoading;
    BOOL _identityRegenerating;
    BOOL _firstSetupInProgress;
    NSUInteger _generation;
    NSUInteger _announcementIndex;
    BOOL _running;
    BOOL _scanStarted;
    BOOL _foundThisScan;
    NSTimeInterval _scanStart;
    NSTimeInterval _lastInterfaceCheck;
}

+ (LocalSendDiscovery *)sharedDiscovery;
+ (NSString *)deviceName;
+ (BOOL)setDeviceName:(NSString *)name;
- (BOOL)hasLocalNetworkInterface;
- (void)start;
- (void)stop;
- (void)refresh;
- (BOOL)isFirstSetupInProgress;
- (BOOL)isRegeneratingIdentity;
- (BOOL)regenerateIdentity;
- (LocalSendCertificateDateStatus)certificateDateStatus;
- (NSString *)identityFingerprint;
- (NSArray *)devices;
@end
