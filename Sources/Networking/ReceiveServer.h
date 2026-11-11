#import <Foundation/Foundation.h>
#import <Security/Security.h>

@class ReceiveServer;

// All delegate methods run on a connection worker, never on the main thread.
// Response dictionaries contain NSNumber "status" and NSData "body".
@protocol ReceiveServerDelegate <NSObject>
- (NSDictionary *)receiveServer:(ReceiveServer *)server
              responseForMethod:(NSString *)method
                         target:(NSString *)target
                        headers:(NSDictionary *)headers
                           body:(NSData *)body
                           peer:(NSDictionary *)peer;
- (id)receiveServer:(ReceiveServer *)server
    beginUploadToTarget:(NSString *)target
                headers:(NSDictionary *)headers
                   peer:(NSDictionary *)peer
            errorStatus:(NSInteger *)status;
- (BOOL)receiveServer:(ReceiveServer *)server upload:(id)upload appendData:(NSData *)data;
- (NSInteger)receiveServer:(ReceiveServer *)server finishUpload:(id)upload;
- (void)receiveServer:(ReceiveServer *)server abortUpload:(id)upload;
@end

@interface ReceiveServer : NSObject {
    SecIdentityRef _identity;
    id<ReceiveServerDelegate> _delegate;
    NSMutableSet *_connections;
    BOOL _invalidated;
}
- (id)initWithIdentity:(SecIdentityRef)identity delegate:(id<ReceiveServerDelegate>)delegate;
// Takes ownership of the socket, including when the connection limit is reached.
- (void)acceptSocket:(int)socketDescriptor address:(NSString *)address;
// Safe to call during a worker delegate callback while waiting for approval.
// Outside this server's worker it returns YES unless the server was invalidated.
- (BOOL)isCurrentConnectionOpen;
// Interrupts workers; their retained delegate callbacks can still finish.
- (BOOL)isInvalidated;
- (void)invalidate;
@end
