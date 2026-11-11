#import <Foundation/Foundation.h>
#import <Security/Security.h>
@class ConnectionActivity;

typedef enum {
    TLSOperationFailed = -1,
    TLSConnectionClosed = 0,
    TLSOperationCompleted = 1,
    TLSOperationWouldBlock = 2
} TLSOperationResult;

/* Owns the TLS state, never the nonblocking socket. Call close before closing
 * the socket. Application data must wait for a successful handshake and any
 * application-level peer fingerprint authorization. */
@interface TLS : NSObject {
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
    ConnectionActivity *_activity;
}
+ (NSString *)libraryVersion;
+ (NSString *)lastInitializationError;
- (id)initWithIdentity:(SecIdentityRef)identity socket:(int)socketDescriptor server:(BOOL)server;
- (id)initWithIdentity:(SecIdentityRef)identity socket:(int)socketDescriptor server:(BOOL)server
              activity:(ConnectionActivity *)activity;
- (TLSOperationResult)handshake;
- (TLSOperationResult)read:(void *)buffer length:(size_t)length processed:(size_t *)processed;
- (TLSOperationResult)write:(const void *)buffer length:(size_t)length processed:(size_t *)processed;
- (BOOL)wantsRead;
- (NSString *)peerFingerprint;
- (NSString *)errorMessage;
- (void)close;
@end
