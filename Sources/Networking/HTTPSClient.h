#import <Foundation/Foundation.h>
#import <Security/Security.h>

@class HTTPSClient;
@class ConnectionActivity;

@protocol HTTPSClientDelegate <NSObject>
- (void)httpsClient:(HTTPSClient *)transport
    didCompleteWithStatus:(NSInteger)status
                     body:(NSData *)body;
- (void)httpsClient:(HTTPSClient *)transport didFailWithMessage:(NSString *)message;
- (void)httpsClient:(HTTPSClient *)transport
    didSendBodyBytes:(unsigned long long)sent
          totalBytes:(unsigned long long)total;
@end

@interface HTTPSClient : NSObject {
    NSString *_host;
    NSNumber *_port;
    NSString *_expectedFingerprint;
    SecIdentityRef _identity;
    id<HTTPSClientDelegate> _delegate;
    BOOL _cancelled;
    BOOL _running;
    int _socketDescriptor;
    BOOL _discoveryOnly;
    NSTimeInterval _discoveryDeadline;
    NSString *_peerFingerprint;
    ConnectionActivity *_activity;
    unsigned long long _progressSent;
    unsigned long long _progressTotal;
    BOOL _progressDeliveryPending;
    NSTimeInterval _lastProgressScheduledAt;
}

- (id)initWithHost:(NSString *)host
                   port:(NSNumber *)port
               identity:(SecIdentityRef)identity
    expectedFingerprint:(NSString *)expectedFingerprint
               delegate:(id<HTTPSClientDelegate>)delegate;
- (void)postPath:(NSString *)path body:(NSData *)body contentType:(NSString *)contentType;
- (void)postPath:(NSString *)path bodyFile:(NSString *)filePath contentType:(NSString *)contentType;
// Discovery alone may learn an unknown certificate. Transfer requests remain pinned.
- (void)postDiscoveryBody:(NSData *)body;
- (NSString *)peerFingerprint;
- (NSString *)diagnosticStatus;
- (BOOL)isRunning;
- (void)invalidate;

@end
