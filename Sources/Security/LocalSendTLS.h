#import <Foundation/Foundation.h>
#import <Security/Security.h>

typedef enum {
    LocalSendTLSOperationFailed = -1,
    LocalSendTLSConnectionClosed = 0,
    LocalSendTLSOperationCompleted = 1,
    LocalSendTLSOperationWouldBlock = 2
} LocalSendTLSOperationResult;

/* Owns the TLS state, never the nonblocking socket. Call close before closing
 * the socket. Application data must wait for a successful handshake and any
 * application-level peer fingerprint authorization. */
@interface LocalSendTLS : NSObject {
  @private
    void *_tlsContext;
    void *_tlsSession;
    SecKeyRef _privateKey;
    void *_keyContext;
    NSString *_peerFingerprint;
    NSString *_errorMessage;
    BOOL _isServer;
    BOOL _wantsRead;
    BOOL _handshakeComplete;
}
+ (NSString *)libraryVersion;
- (id)initWithIdentity:(SecIdentityRef)identity socket:(int)socketDescriptor server:(BOOL)server;
- (LocalSendTLSOperationResult)handshake;
- (LocalSendTLSOperationResult)read:(void *)buffer length:(size_t)length processed:(size_t *)processed;
- (LocalSendTLSOperationResult)write:(const void *)buffer length:(size_t)length processed:(size_t *)processed;
- (BOOL)wantsRead;
- (NSString *)peerFingerprint;
- (NSString *)errorMessage;
- (void)close;
@end
