#import "ReceiveServer.h"
#import "TLS.h"
#import "ConnectionActivity.h"

typedef struct {
    int socketDescriptor;
    BOOL wantsRead;
} IncomingSocket;

@interface IncomingConnection : NSObject {
  @public
    IncomingSocket socket;
    TLS *tls;
    ConnectionActivity *activity;
    NSString *address;
    NSString *peerFingerprint;
    NSMutableData *pendingData;
    NSInteger errorStatus;
    BOOL waitingForResponse;
    ReceiveServer *server; // Worker retains the server through its NSThread target.
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
               delegate:(id<ReceiveServerDelegate>)delegate
                 upload:(id)upload;
@end
