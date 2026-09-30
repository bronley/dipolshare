#import "LocalSendJSON.h"
#import "LocalSendDiscoveryProbe.h"
#import "LocalSendDiscoveryMessage.h"

@implementation LocalSendDiscoveryProbe

- (NSDictionary *)endpoint {
    return endpoint;
}
- (NSUInteger)generation {
    return generation;
}
- (NSTimeInterval)startedAt {
    return startedAt;
}
- (BOOL)hasRunningWorker {
    return [_transport isRunning];
}
- (NSString *)failureMessage {
    if (_failureMessage == nil && _transport != nil) {
        return [NSString stringWithFormat:@"Registration timed out: %@", [_transport diagnosticStatus]];
    }
    return _failureMessage;
}

- (id)initWithDelegate:(id<LocalSendDiscoveryProbeDelegate>)delegate
              endpoint:(NSDictionary *)value
            generation:(NSUInteger)valueGeneration {
    if ((self = [super init])) {
        _delegate = delegate;
        endpoint = [value copy];
        generation = valueGeneration;
        startedAt = [NSDate timeIntervalSinceReferenceDate];
    }
    return self;
}
- (void)startWithIdentity:(SecIdentityRef)identity info:(NSDictionary *)info {
    NSData *body = [LocalSendJSON dataWithJSONObject:info options:0 error:NULL];
    if ([[endpoint objectForKey:@"protocol"] isEqual:@"https"]) {
        _transport = [[LocalSendHTTPSClient alloc] initWithHost:[endpoint objectForKey:@"address"]
                                                           port:[endpoint objectForKey:@"port"]
                                                       identity:identity
                                            expectedFingerprint:[endpoint objectForKey:@"fingerprint"]
                                                       delegate:self];
        [_transport postDiscoveryBody:body];
    } else {
        NSString *url =
            [NSString stringWithFormat:@"http://%@:%@/api/localsend/v2/register",
                                       [endpoint objectForKey:@"address"], [endpoint objectForKey:@"port"]];
        NSMutableURLRequest *request =
            [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                timeoutInterval:2.0];
        [request setHTTPMethod:@"POST"];
        [request setHTTPBody:body];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        _data = [[NSMutableData alloc] init];
        _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
        [_connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        [_connection start];
    }
}
- (void)finish:(NSData *)data status:(NSInteger)status fingerprint:(NSString *)fingerprint {
    [self retain];
    if (status != 200 && _failureMessage == nil) {
        _failureMessage = [[NSString stringWithFormat:@"Registration returned HTTP %ld.", (long)status] copy];
    }
    id object = status == 200 ? [LocalSendJSON JSONObjectWithData:data options:0 error:NULL] : nil;
    NSMutableDictionary *message =
        [object isKindOfClass:[NSDictionary class]] ? [[object mutableCopy] autorelease] : nil;
    if (status == 200 && message == nil && _failureMessage == nil) {
        _failureMessage = [@"Registration response is not a JSON object." copy];
    }
    if (message != nil) {
        [message setObject:[endpoint objectForKey:@"port"] forKey:@"port"];
        [message setObject:[endpoint objectForKey:@"protocol"] forKey:@"protocol"];
        if (fingerprint != nil) {
            [message setObject:fingerprint forKey:@"fingerprint"];
        }
        if (!LocalSendIsValidDiscoveryMessage(message)) {
            message = nil;
            [_failureMessage release];
            _failureMessage = [@"Registration response has invalid device metadata." copy];
        }
    }
    [_delegate discoveryProbe:self didCompleteWithMessage:message];
    [self release];
}
- (void)httpsClient:(LocalSendHTTPSClient *)transport
    didCompleteWithStatus:(NSInteger)status
                     body:(NSData *)body {
    [self finish:body status:status fingerprint:[transport peerFingerprint]];
}
- (void)httpsClient:(LocalSendHTTPSClient *)transport didFailWithMessage:(NSString *)message {
    [_failureMessage release];
    _failureMessage = [message copy];
    [self finish:nil status:0 fingerprint:nil];
}
- (void)httpsClient:(LocalSendHTTPSClient *)transport
    didSendBodyBytes:(unsigned long long)sent
          totalBytes:(unsigned long long)total {
}
- (NSURLRequest *)connection:(NSURLConnection *)connection
             willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)response {
    if (response != nil) {
        [_failureMessage release];
        _failureMessage = [@"Registration redirected to another URL." copy];
        [self finish:nil status:0 fingerprint:nil];
        return nil;
    }
    return request;
}
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    _status = [(NSHTTPURLResponse *)response statusCode];
    [_data setLength:0];
}
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if ([_data length] + [data length] > 16384) {
        [_failureMessage release];
        _failureMessage = [@"Registration response is too large." copy];
        [self finish:nil status:0 fingerprint:nil];
        return;
    }
    [_data appendData:data];
}
- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    [self finish:_data status:_status fingerprint:nil];
}
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [_failureMessage release];
    NSString *failedURL = [[error userInfo] objectForKey:NSURLErrorFailingURLStringErrorKey];
    _failureMessage = [[NSString stringWithFormat:@"%@ (%@ %ld%@%@)",
                       [error localizedDescription], [error domain], (long)[error code],
                       failedURL != nil ? @", " : @"", failedURL ?: @""] copy];
    [self finish:nil status:0 fingerprint:nil];
}
- (void)invalidate {
    _delegate = nil;
    [_connection cancel];
    [_transport invalidate];
}
- (void)dealloc {
    [self invalidate];
    [endpoint release];
    [_transport release];
    [_connection release];
    [_data release];
    [_failureMessage release];
    [super dealloc];
}
@end
