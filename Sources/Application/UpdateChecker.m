#import "UpdateChecker.h"
#import "UpdateManifest.h"

static NSString *const DismissedVersionKey = @"DipolShareDismissedUpdateVersion";
static NSString *const RemindedVersionKey = @"DipolShareRemindedUpdateVersion";
static NSString *const RemindAfterKey = @"DipolShareUpdateRemindAfter";
static const NSUInteger MaximumManifestSize = 16384;

@interface UpdateChecker ()
- (void)requestTimedOut:(NSTimer *)timer;
@end

@implementation UpdateChecker
@synthesize delegate = _delegate;

- (id)initWithURL:(NSURL *)url installedVersion:(NSString *)installed systemVersion:(NSString *)system
        defaults:(NSUserDefaults *)defaults {
    self = [super init];
    if (self) {
        _manifestURL = [url retain];
        _installedVersion = [installed copy];
        _systemVersion = [system copy];
        _defaults = [defaults retain];
    }
    return self;
}

- (void)check {
    if (_connection != nil || (_lastAttempt != nil && -[_lastAttempt timeIntervalSinceNow] < 900.0)) return;
    if (![[_manifestURL scheme] isEqualToString:@"https"] || [[_manifestURL host] length] == 0 ||
        [_manifestURL user] != nil || [_manifestURL password] != nil) return;
    [_lastAttempt release];
    _lastAttempt = [[NSDate date] retain];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_manifestURL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20.0];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    _responseData = [[NSMutableData alloc] init];
    _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    if (_connection == nil) {
        [self cancel];
        return;
    }
    _timeoutTimer = [[NSTimer timerWithTimeInterval:20.0 target:self selector:@selector(requestTimedOut:)
        userInfo:nil repeats:NO] retain];
    [[NSRunLoop mainRunLoop] addTimer:_timeoutTimer forMode:NSRunLoopCommonModes];
    [_connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [_connection start];
}

- (void)cancel {
    [_timeoutTimer invalidate];
    [_timeoutTimer release];
    _timeoutTimer = nil;
    [_connection cancel];
    [_connection release];
    _connection = nil;
    [_responseData release];
    _responseData = nil;
}

- (void)requestTimedOut:(NSTimer *)timer {
    if (timer == _timeoutTimer) [self cancel];
}

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)response {
    if (connection != _connection) return nil;
    if (response != nil) {
        [self cancel];
        return nil;
    }
    return request;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if (connection != _connection) return;
    if (![response isKindOfClass:[NSHTTPURLResponse class]] ||
        [(NSHTTPURLResponse *)response statusCode] != 200 ||
        [response expectedContentLength] > (long long)MaximumManifestSize) {
        [self cancel];
        return;
    }
    [_responseData setLength:0];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (connection != _connection) return;
    if ([data length] > MaximumManifestSize - [_responseData length]) {
        [self cancel];
        return;
    }
    [_responseData appendData:data];
}

- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)response {
    return nil;
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    if (connection != _connection) return;
    NSData *body = [[_responseData copy] autorelease];
    [self cancel];
    NSString *version = [UpdateManifest newerVersionFromData:body installedVersion:_installedVersion systemVersion:_systemVersion];
    if ([UpdateManifest shouldNotifyVersion:version dismissedVersion:[_defaults stringForKey:DismissedVersionKey]
        remindedVersion:[_defaults stringForKey:RemindedVersionKey] remindAfter:[_defaults objectForKey:RemindAfterKey]
        now:[NSDate date]]) {
        [_delegate updateChecker:self foundVersion:version];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    if (connection == _connection) [self cancel];
}

- (void)dismissVersion:(NSString *)version {
    [_defaults setObject:version forKey:DismissedVersionKey];
    [_defaults removeObjectForKey:RemindedVersionKey];
    [_defaults removeObjectForKey:RemindAfterKey];
    [_defaults synchronize];
}

- (void)remindLaterForVersion:(NSString *)version {
    [_defaults setObject:version forKey:RemindedVersionKey];
    [_defaults setObject:[NSDate dateWithTimeIntervalSinceNow:24 * 60 * 60] forKey:RemindAfterKey];
    [_defaults synchronize];
}

- (void)dealloc {
    [self cancel];
    [_manifestURL release];
    [_installedVersion release];
    [_systemVersion release];
    [_defaults release];
    [_lastAttempt release];
    [super dealloc];
}
@end
