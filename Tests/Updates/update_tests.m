#import "UpdateManifest.h"
#import "UpdateChecker.h"
#import "JSON.h"

static NSUInteger checks, failures;
static void Check(BOOL passed, NSString *label) {
    checks++;
    if (!passed) failures++;
    printf("%s %s\n", passed ? "PASS" : "FAIL", [label UTF8String]);
}
static NSData *Data(id object) { return [JSON dataWithJSONObject:object options:0 error:NULL]; }

@interface UpdateChecker (ConnectionCallbacks)
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response;
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data;
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error;
- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)response;
- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)response;
- (void)connectionDidFinishLoading:(NSURLConnection *)connection;
- (void)requestTimedOut:(NSTimer *)timer;
@end

@interface TestConnection : NSObject { @public BOOL cancelled; }
- (void)cancel;
@end
@implementation TestConnection
- (void)cancel { cancelled = YES; }
@end

@interface TestDefaults : NSUserDefaults { NSMutableDictionary *_values; }
@end
@implementation TestDefaults
- (id)init { if ((self = [super init])) _values = [NSMutableDictionary new]; return self; }
- (id)objectForKey:(NSString *)key { return [_values objectForKey:key]; }
- (NSString *)stringForKey:(NSString *)key { return [self objectForKey:key]; }
- (void)setObject:(id)value forKey:(NSString *)key { [_values setObject:value forKey:key]; }
- (void)removeObjectForKey:(NSString *)key { [_values removeObjectForKey:key]; }
- (BOOL)synchronize { return YES; }
- (void)dealloc { [_values release]; [super dealloc]; }
@end

@interface TestChecker : UpdateChecker
- (NSURLConnection *)beginResponse;
- (BOOL)isFetching;
- (void)respond:(NSInteger)status body:(NSData *)body;
- (void)fail;
- (void)expireRequest;
@end
@implementation TestChecker
- (NSURLConnection *)beginResponse {
    [self cancel];
    _connection = (NSURLConnection *)[TestConnection new];
    _responseData = [NSMutableData new];
    return [[_connection retain] autorelease];
}
- (BOOL)isFetching { return _connection != nil; }
- (void)respond:(NSInteger)status body:(NSData *)body {
    NSURLConnection *connection = [self beginResponse];
    NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://example.com/latest.json"]
        statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:nil] autorelease];
    [self connection:connection didReceiveResponse:response];
    [self connection:connection didReceiveData:body];
    [self connectionDidFinishLoading:connection];
}
- (void)fail {
    NSURLConnection *connection = [self beginResponse];
    [self connection:connection didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
}
- (void)expireRequest {
    _timeoutTimer = [[NSTimer timerWithTimeInterval:20 target:self selector:@selector(requestTimedOut:) userInfo:nil repeats:NO] retain];
    [self requestTimedOut:_timeoutTimer];
}
@end

@interface Observer : NSObject <UpdateCheckerDelegate> { @public NSUInteger calls; NSString *latest; }
@end
@implementation Observer
- (void)updateChecker:(UpdateChecker *)checker foundVersion:(NSString *)version {
    calls++; [latest release]; latest = [version copy];
}
- (void)dealloc { [latest release]; [super dealloc]; }
@end

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    if (argc == 2) {
        UpdateChecker *live = [[UpdateChecker alloc] initWithURL:[NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]]
            installedVersion:@"1.0.3" systemVersion:@"5.1.1" defaults:[[[TestDefaults alloc] init] autorelease]];
        Observer *result = [Observer new];
        live.delegate = result;
        [live check];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:25];
        while (result->calls == 0 && [deadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        Check(result->calls == 1 && [result->latest isEqual:@"1.1.0"], @"live manifest fetched using system HTTPS");
        [live cancel]; [live release]; [result release];
        [pool drain];
        return failures ? 1 : 0;
    }
    for (NSString *version in @[@"1.0.4", @"1.0.10", @"1.1", @"2", @"1.0.3.1"]) {
        Check([[UpdateManifest newerVersionFromData:Data(@{@"version":version}) installedVersion:@"1.0.3" systemVersion:@"5.1.1"] isEqual:version],
              [@"newer numeric version: " stringByAppendingString:version]);
    }
    for (id version in @[@"1.0.3", @"1.0.3.0", @"01.00.003", @"1.0.2", @"0.99", @"", @"1..4", @"1.0.4-beta", @" 2.0", @"2.0\n", @"-2", @"2.0.0.0.1", @"9999999999", @4, [NSNull null], @[]]) {
        Check([UpdateManifest newerVersionFromData:Data(@{@"version":version}) installedVersion:@"1.0.3" systemVersion:@"5.1.1"] == nil,
              [NSString stringWithFormat:@"equal, older or malformed version is silent: %@", version]);
    }
    Check([UpdateManifest newerVersionFromData:Data(@{@"version":@"1.0.4", @"minimumOSVersion":@"6.0"}) installedVersion:@"1.0.3" systemVersion:@"5.1.1"] == nil, @"unsupported OS receives no update prompt");
    Check([UpdateManifest newerVersionFromData:Data(@{@"version":@"1.0.4", @"minimumOSVersion":@"4.2"}) installedVersion:@"1.0.3" systemVersion:@"4.2.1"] != nil, @"compatible classic iOS accepts update");
    Check([UpdateManifest newerVersionFromData:Data(@{@"version":@"1.0.4", @"minimumOSVersion":@5}) installedVersion:@"1.0.3" systemVersion:@"5.1.1"] == nil, @"invalid minimum OS is silent");
    Check([UpdateManifest newerVersionFromData:Data(@{@"version":@"1.0.4"}) installedVersion:@"broken" systemVersion:@"5.1.1"] == nil, @"invalid installed version is silent");
    for (NSData *bad in @[[NSData data], [@"{broken" dataUsingEncoding:NSUTF8StringEncoding], Data(@[]), Data(@{}), [NSMutableData dataWithLength:16385]]) {
        Check([UpdateManifest newerVersionFromData:bad installedVersion:@"1.0.3" systemVersion:@"5.1.1"] == nil, @"empty, malformed, missing or oversized manifest is silent");
    }
    TestDefaults *defaults = [TestDefaults new];
    TestChecker *checker = [[TestChecker alloc] initWithURL:[NSURL URLWithString:@"https://example.com/latest.json"]
        installedVersion:@"1.0.3" systemVersion:@"5.1.1" defaults:defaults];
    Observer *observer = [Observer new]; checker.delegate = observer;
    NSData *newVersion = Data(@{@"version":@"1.0.4"});
    [checker fail];
    for (NSNumber *status in @[@204, @301, @304, @404, @500]) [checker respond:[status integerValue] body:newVersion];
    [checker respond:200 body:Data(@{@"version":@"1.0.3"})];
    [checker respond:200 body:Data(@{@"version":@"1.0.2"})];
    [checker respond:200 body:[@"not JSON" dataUsingEncoding:NSUTF8StringEncoding]];
    Check(observer->calls == 0, @"network failures, HTTP errors, bad JSON and non-newer versions never notify");
    [checker respond:200 body:newVersion];
    Check(observer->calls == 1 && [observer->latest isEqual:@"1.0.4"], @"successful new manifest notifies with its version");
    [checker dismissVersion:@"1.0.4"];
    [checker respond:200 body:newVersion];
    Check(observer->calls == 1, @"Dismiss suppresses the same release");
    [checker release];
    checker = [[TestChecker alloc] initWithURL:nil installedVersion:@"1.0.3" systemVersion:@"5.1.1" defaults:defaults];
    checker.delegate = observer;
    [checker respond:200 body:newVersion];
    Check(observer->calls == 1, @"dismissal survives checker recreation");
    NSData *next = Data(@{@"version":@"1.0.5"});
    [checker respond:200 body:next];
    Check(observer->calls == 2, @"a later release is not hidden by a previous dismissal");
    [checker remindLaterForVersion:@"1.0.5"];
    [checker respond:200 body:next];
    NSDate *until = [defaults objectForKey:@"DipolShareUpdateRemindAfter"];
    Check(observer->calls == 2 && [until timeIntervalSinceNow] > 86395, @"Remind Later suppresses that release for 24 hours");
    [defaults setObject:[NSDate dateWithTimeIntervalSinceNow:-1] forKey:@"DipolShareUpdateRemindAfter"];
    [checker respond:200 body:next];
    Check(observer->calls == 3, @"expired reminder permits notification after a successful fetch");
    [checker remindLaterForVersion:@"1.0.5"];
    [checker respond:200 body:Data(@{@"version":@"1.0.6"})];
    Check(observer->calls == 4, @"a newer release bypasses a previous release reminder");
    [checker fail];
    Check(observer->calls == 4, @"later fetch failures do not replay a cached notice");
    NSURLConnection *connection = [checker beginResponse];
    [checker connection:connection didReceiveData:[NSMutableData dataWithLength:16384]];
    Check([checker isFetching], @"response accepts exactly the 16 KiB limit");
    [checker connection:connection didReceiveData:[NSData dataWithBytes:"x" length:1]];
    Check(![checker isFetching] && ((TestConnection *)connection)->cancelled, @"streaming response exceeding limit is cancelled");
    [checker connectionDidFinishLoading:connection];
    Check(observer->calls == 4, @"late completion after cancellation is silent");

    connection = [checker beginResponse];
    NSHTTPURLResponse *oversized = [[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://example.com/latest.json"]
        statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Length":@"16385"}] autorelease];
    [checker connection:connection didReceiveResponse:oversized];
    Check(![checker isFetching], @"oversized declared response is cancelled before buffering");

    connection = [checker beginResponse];
    NSURLRequest *redirect = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://example.com/latest.json"]];
    Check([checker connection:connection willSendRequest:redirect redirectResponse:oversized] == nil && ![checker isFetching],
        @"redirects are rejected, including HTTPS downgrades");

    connection = [checker beginResponse];
    [checker expireRequest];
    Check(![checker isFetching] && ((TestConnection *)connection)->cancelled, @"total request deadline cancels the connection");

    connection = [checker beginResponse];
    [checker connection:connection didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorServerCertificateUntrusted userInfo:nil]];
    Check(![checker isFetching] && observer->calls == 4, @"system certificate failures are silent");
    Check([checker connection:connection willCacheResponse:nil] == nil, @"manifest responses are not cached");

    [checker check];
    Check(![checker isFetching], @"missing manifest URL does not start a request");
    [checker release]; [defaults release]; [observer release];
    printf("%lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
    [pool drain]; return failures ? 1 : 0;
}
