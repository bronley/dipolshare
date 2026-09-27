#import <Foundation/Foundation.h>
#import <Security/Security.h>

@class LocalSendReceiveServer;

// All delegate methods run on a connection worker, never on the main thread.
// Response dictionaries contain NSNumber "status" and NSData "body".
@protocol LocalSendReceiveServerDelegate <NSObject>
- (NSDictionary *)receiveServer:(LocalSendReceiveServer *)server
              responseForMethod:(NSString *)method
                         target:(NSString *)target
                        headers:(NSDictionary *)headers
                           body:(NSData *)body
                           peer:(NSDictionary *)peer;
- (id)receiveServer:(LocalSendReceiveServer *)server
    beginUploadToTarget:(NSString *)target
                headers:(NSDictionary *)headers
                   peer:(NSDictionary *)peer
            errorStatus:(NSInteger *)status;
- (BOOL)receiveServer:(LocalSendReceiveServer *)server upload:(id)upload appendData:(NSData *)data;
- (NSInteger)receiveServer:(LocalSendReceiveServer *)server finishUpload:(id)upload;
- (void)receiveServer:(LocalSendReceiveServer *)server abortUpload:(id)upload;
@end

@interface LocalSendReceiveServer : NSObject {
    SecIdentityRef _identity;
    id<LocalSendReceiveServerDelegate> _delegate;
    NSMutableSet *_connections;
    BOOL _invalidated;
}
- (id)initWithIdentity:(SecIdentityRef)identity delegate:(id<LocalSendReceiveServerDelegate>)delegate;
// Takes ownership of the socket, including when the connection limit is reached.
- (void)acceptSocket:(int)socketDescriptor address:(NSString *)address;
// Safe to call during a worker delegate callback while waiting for approval.
// Outside this server's worker it returns YES unless the server was invalidated.
- (BOOL)isCurrentConnectionOpen;
// Interrupts workers; their retained delegate callbacks can still finish.
- (BOOL)isInvalidated;
- (void)invalidate;
@end
