#import "LocalSendReceiveServer.h"
#import "LocalSendTLS.h"

typedef struct {
    int socketDescriptor;
    BOOL wantsRead;
} LocalSendIncomingSocket;

@interface LocalSendIncomingConnection : NSObject {
  @public
    LocalSendIncomingSocket socket;
    LocalSendTLS *tls;
    NSString *address;
    NSString *peerFingerprint;
    NSMutableData *pendingData;
    NSInteger errorStatus;
    BOOL waitingForResponse;
    LocalSendReceiveServer *server; // Worker retains the server through its NSThread target.
}
- (BOOL)waitUntil:(NSTimeInterval)deadline;
- (NSData *)readDataUpToLength:(NSUInteger)limit;
- (NSString *)readLineUpToLength:(NSUInteger)limit;
- (BOOL)writeData:(NSData *)data;
- (void)sendResponseWithStatus:(NSInteger)status body:(NSData *)body;
- (BOOL)startTLS:(SecIdentityRef)identity;
- (BOOL)isOpen;
- (BOOL)prepareForRequestWithIdentity:(SecIdentityRef)identity;
- (NSDictionary *)readRequest;
- (BOOL)readRequestBody:(NSDictionary *)request
               intoData:(NSMutableData *)body
               delegate:(id<LocalSendReceiveServerDelegate>)delegate
                 upload:(id)upload;
@end
