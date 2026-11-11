#import <Foundation/Foundation.h>
#import "HTTPSClient.h"

@class DiscoveryProbe;

@protocol DiscoveryProbeDelegate <NSObject>
- (void)discoveryProbe:(DiscoveryProbe *)probe didCompleteWithMessage:(NSDictionary *)message;
@end

@interface DiscoveryProbe : NSObject <NSURLConnectionDelegate, HTTPSClientDelegate> {
  @private
    NSDictionary *endpoint;
    NSUInteger generation;
    NSTimeInterval startedAt;
    id<DiscoveryProbeDelegate> _delegate;
    HTTPSClient *_transport;
    NSURLConnection *_connection;
    NSMutableData *_data;
    NSInteger _status;
    NSString *_failureMessage;
}
- (id)initWithDelegate:(id<DiscoveryProbeDelegate>)delegate
              endpoint:(NSDictionary *)endpoint
            generation:(NSUInteger)generation;
- (NSDictionary *)endpoint;
- (NSUInteger)generation;
- (NSTimeInterval)startedAt;
- (NSString *)failureMessage;
- (BOOL)hasRunningWorker;
- (void)startWithIdentity:(SecIdentityRef)identity info:(NSDictionary *)info;
- (void)invalidate;
@end
