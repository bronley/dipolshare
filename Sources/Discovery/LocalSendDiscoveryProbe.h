#import <Foundation/Foundation.h>
#import "LocalSendHTTPSClient.h"

@class LocalSendDiscoveryProbe;

@protocol LocalSendDiscoveryProbeDelegate <NSObject>
- (void)discoveryProbe:(LocalSendDiscoveryProbe *)probe didCompleteWithMessage:(NSDictionary *)message;
@end

@interface LocalSendDiscoveryProbe : NSObject <NSURLConnectionDelegate, LocalSendHTTPSClientDelegate> {
  @private
    NSDictionary *endpoint;
    NSUInteger generation;
    NSTimeInterval startedAt;
    id<LocalSendDiscoveryProbeDelegate> _delegate;
    LocalSendHTTPSClient *_transport;
    NSURLConnection *_connection;
    NSMutableData *_data;
    NSInteger _status;
}
- (id)initWithDelegate:(id<LocalSendDiscoveryProbeDelegate>)delegate
              endpoint:(NSDictionary *)endpoint
            generation:(NSUInteger)generation;
- (NSDictionary *)endpoint;
- (NSUInteger)generation;
- (NSTimeInterval)startedAt;
- (void)startWithIdentity:(SecIdentityRef)identity info:(NSDictionary *)info;
- (void)invalidate;
@end
