#import <Foundation/Foundation.h>
#import <Security/Security.h>

@class LocalSendHTTPSClient;

@protocol LocalSendHTTPSClientDelegate <NSObject>
- (void)httpsClient:(LocalSendHTTPSClient *)transport
    didCompleteWithStatus:(NSInteger)status
                     body:(NSData *)body;
- (void)httpsClient:(LocalSendHTTPSClient *)transport didFailWithMessage:(NSString *)message;
- (void)httpsClient:(LocalSendHTTPSClient *)transport
    didSendBodyBytes:(NSUInteger)sent
          totalBytes:(NSUInteger)total;
@end

@interface LocalSendHTTPSClient : NSObject {
    NSString *_host;
    NSNumber *_port;
    NSString *_expectedFingerprint;
    SecIdentityRef _identity;
    id<LocalSendHTTPSClientDelegate> _delegate;
    BOOL _cancelled;
    BOOL _running;
    BOOL _discoveryOnly;
    NSTimeInterval _discoveryDeadline;
    NSString *_peerFingerprint;
}

- (id)initWithHost:(NSString *)host
                   port:(NSNumber *)port
               identity:(SecIdentityRef)identity
    expectedFingerprint:(NSString *)expectedFingerprint
               delegate:(id<LocalSendHTTPSClientDelegate>)delegate;
- (void)postPath:(NSString *)path body:(NSData *)body contentType:(NSString *)contentType;
- (void)postPath:(NSString *)path bodyFile:(NSString *)filePath contentType:(NSString *)contentType;
// Discovery alone may learn an unknown certificate. Transfer requests remain pinned.
- (void)postDiscoveryBody:(NSData *)body;
- (NSString *)peerFingerprint;
- (void)invalidate;

@end
