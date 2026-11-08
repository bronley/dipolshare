#import "Discovery.h"

@class IdentityLoadResult;

extern const unsigned short kLocalSendPort;
NSArray *DiscoveryNetworkInterfaces(void);

// Internal declarations shared by the implementation files.
@interface Discovery ()
- (void)configureLocalDeviceWithFingerprint:(NSString *)fingerprint;
- (void)updateDeviceName;
- (void)finishStartingWithFingerprint:(NSString *)fingerprint;
- (BOOL)isLocalAddress:(NSString *)address;
- (void)recordMessage:(NSDictionary *)message address:(NSString *)address;
- (void)peerRegistered:(NSNotification *)notification;
@end

@interface Discovery (IdentityInternal)
- (void)loadIdentityInBackground;
- (void)firstSetupStarted:(id)unused;
- (void)identityLoaded:(IdentityLoadResult *)result;
- (BOOL)isFirstSetupInProgress;
- (BOOL)isRegeneratingIdentity;
- (CertificateDateStatus)certificateDateStatus;
- (NSString *)identityFingerprint;
- (NSString *)identitySetupError;
- (BOOL)regenerateIdentity;
- (void)regenerateIdentityInBackground;
- (void)identityRegenerated:(IdentityLoadResult *)result;
@end

@interface Discovery (NetworkInternal)
- (void)startIncomingListener;
- (void)startMulticastDiscovery;
- (BOOL)hasLocalNetworkInterface;
- (void)announceIfDue;
- (void)announce;
- (void)readDatagrams;
- (void)acceptSocket:(int)socketDescriptor address:(NSData *)address;
@end

@interface Discovery (Scanning)
- (void)startDiscoveryTimer;
- (void)cancelScan;
- (void)beginScan;
- (void)startSubnetScan;
- (void)checkActiveSubnetConnections;
- (void)startPendingSubnetConnections;
- (void)advanceSubnetScan;
- (void)tick:(NSTimer *)timer;
@end

@interface Discovery (Probes) <DiscoveryProbeDelegate>
- (void)retireProbe:(DiscoveryProbe *)probe;
- (void)reapRetiredProbes;
- (void)enqueueProbe:(NSDictionary *)endpoint;
- (void)startPendingDiscoveryProbes;
- (void)discoveryProbe:(DiscoveryProbe *)probe didCompleteWithMessage:(NSDictionary *)message;
@end
