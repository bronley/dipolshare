#import <Foundation/Foundation.h>
#import "LocalSendTransfer.h"
#import "LocalSendIdentityStore.h"
#import "LocalSendSounds.h"

static NSUInteger CompletionSoundCount = 0;

@implementation ALAssetsLibrary
@end

@implementation ALAssetRepresentation
- (id)initWithData:(NSData *)data fileName:(NSString *)fileName fail:(BOOL)shouldFail {
    self = [super init];
    if (self) {
        _testData = [data copy];
        _testFileName = [fileName copy];
        _testShouldFail = shouldFail;
    }
    return self;
}
- (NSString *)filename {
    return _testFileName;
}
- (NSUInteger)size {
    return [_testData length];
}
- (NSUInteger)testReadCount {
    return _testReadCount;
}
- (NSUInteger)getBytes:(uint8_t *)bytes
            fromOffset:(long long)offset
                length:(NSUInteger)length
                 error:(NSError **)error {
    _testReadCount++;
    if (_testShouldFail && offset >= 32768) {
        *error = [NSError errorWithDomain:@"PhotoTest" code:1 userInfo:nil];
        return 0;
    }
    NSUInteger byteCount = MIN(length, [_testData length] - (NSUInteger)offset);
    [_testData getBytes:bytes range:NSMakeRange((NSUInteger)offset, byteCount)];
    return byteCount;
}
- (void)dealloc {
    [_testData release];
    [_testFileName release];
    [super dealloc];
}
@end

@implementation ALAsset
- (id)initWithRepresentation:(ALAssetRepresentation *)representation {
    self = [super init];
    if (self) {
        _testRepresentation = [representation retain];
    }
    return self;
}
- (ALAssetRepresentation *)defaultRepresentation {
    return _testRepresentation;
}
- (void)dealloc {
    [_testRepresentation release];
    [super dealloc];
}
@end

@implementation LocalSendIdentityStore
+ (SecIdentityRef)copyIdentityWithFingerprint:(NSString **)fingerprint error:(NSString **)errorMessage {
    *fingerprint = @"test-fingerprint";
    return (SecIdentityRef)CFRetain(kCFBooleanTrue);
}
@end

@implementation LocalSendSounds
+ (void)playOutgoingTransferComplete {
    CompletionSoundCount++;
}
+ (void)playIncomingTransfer {
}
@end

@implementation LocalSendHTTPSClient
- (id)initWithHost:(NSString *)host
                   port:(NSNumber *)port
               identity:(SecIdentityRef)identity
    expectedFingerprint:(NSString *)fingerprint
               delegate:(id)delegate {
    return [super init];
}
- (void)postDiscoveryBody:(NSData *)body {
}
- (NSString *)peerFingerprint {
    return @"test-fingerprint";
}
- (void)invalidate {
}
- (void)postPath:(NSString *)path body:(NSData *)body contentType:(NSString *)contentType {
}
- (void)postPath:(NSString *)path bodyFile:(NSString *)filePath contentType:(NSString *)contentType {
}
@end

@interface LocalSendTransfer (TestMethods)
- (void)handleResponseData:(NSData *)data statusCode:(NSInteger)statusCode;
- (void)beginRequestToPath:(NSString *)path
                      body:(NSData *)body
                  bodyFile:(NSString *)filePath
               contentType:(NSString *)contentType;
- (void)preparePhotoFile:(NSDictionary *)file;
- (void)photoFilePrepared:(NSDictionary *)result;
- (NSURLRequest *)connection:(NSURLConnection *)connection
             willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)response;
@end

@interface RecordingTransfer : LocalSendTransfer {
    NSMutableArray *_recordedRequests;
    NSDictionary *_lastStatus;
    NSDictionary *_exportResult;
    BOOL _captureExportOnly;
}
- (NSArray *)recordedRequests;
- (NSDictionary *)lastStatus;
- (NSDictionary *)exportResult;
- (void)setCaptureExportOnly:(BOOL)value;
- (void)recordStatus:(NSNotification *)notification;
@end

@implementation RecordingTransfer
- (NSArray *)recordedRequests {
    return _recordedRequests;
}
- (NSDictionary *)lastStatus {
    return _lastStatus;
}
- (NSDictionary *)exportResult {
    return _exportResult;
}
- (void)setCaptureExportOnly:(BOOL)value {
    _captureExportOnly = value;
}
- (void)recordStatus:(NSNotification *)notification {
    [_lastStatus release];
    _lastStatus = [[notification userInfo] copy];
}
- (void)beginRequestToPath:(NSString *)path
                      body:(NSData *)body
                  bodyFile:(NSString *)filePath
               contentType:(NSString *)contentType {
    if (_recordedRequests == nil) {
        _recordedRequests = [[NSMutableArray alloc] init];
    }
    NSData *contents = filePath == nil ? body : [NSData dataWithContentsOfFile:filePath];
    [_recordedRequests
        addObject:[NSDictionary dictionaryWithObjectsAndKeys:path, @"path", contents ?: [NSData data],
                                                             @"body", filePath ?: @"", @"temporaryPath",
                                                             contentType, @"contentType", nil]];
}
- (void)photoFilePrepared:(NSDictionary *)result {
    if (_captureExportOnly) {
        [_exportResult release];
        _exportResult = [result copy];
        return;
    }
    [super photoFilePrepared:result];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_recordedRequests release];
    [_lastStatus release];
    [_exportResult release];
    [super dealloc];
}
@end

static NSUInteger TestCount = 0;
static NSUInteger FailureCount = 0;

static void Check(BOOL condition, const char *description) {
    TestCount++;
    if (!condition) {
        FailureCount++;
    }
    printf("%s %s\n", condition ? "PASS" : "FAIL", description);
}

static void Observe(RecordingTransfer *transfer) {
    [[NSNotificationCenter defaultCenter] addObserver:transfer
                                             selector:@selector(recordStatus:)
                                                 name:LocalSendTransferDidUpdateNotification
                                               object:transfer];
}

static NSDictionary *RequestMetadata(RecordingTransfer *transfer) {
    NSData *body = [[[transfer recordedRequests] objectAtIndex:0] objectForKey:@"body"];
    return [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
}

static NSData *AcceptanceForFiles(NSDictionary *files) {
    NSMutableDictionary *tokens = [NSMutableDictionary dictionary];
    for (NSString *identifier in files) {
        [tokens setObject:[@"token-" stringByAppendingString:identifier] forKey:identifier];
    }
    return [NSJSONSerialization
        dataWithJSONObject:[NSDictionary
                               dictionaryWithObjectsAndKeys:@"session", @"sessionId", tokens, @"files", nil]
                   options:0
                     error:NULL];
}

static void WaitForRequestCount(RecordingTransfer *transfer, NSUInteger count) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
    while ([[transfer recordedRequests] count] < count && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
}

static RecordingTransfer *ClipboardTransfer(NSString *text) {
    NSDictionary *device = [NSDictionary dictionaryWithObject:@"https" forKey:@"protocol"];
    RecordingTransfer *transfer = [[RecordingTransfer alloc] initWithDevice:device clipboardText:text];
    Observe(transfer);
    return [transfer autorelease];
}

static ALAsset *PhotoAsset(NSData *data, NSString *name, BOOL shouldFail) {
    ALAssetRepresentation *representation =
        [[[ALAssetRepresentation alloc] initWithData:data fileName:name fail:shouldFail] autorelease];
    return [[[ALAsset alloc] initWithRepresentation:representation] autorelease];
}

static void TestClipboard(void) {
    NSMutableString *text = [NSMutableString stringWithString:@"Hello 👋\nПривет — https://example.com"];
    NSData *expected = [text dataUsingEncoding:NSUTF8StringEncoding];
    RecordingTransfer *transfer = ClipboardTransfer(text);
    [text appendString:@" changed"];
    [transfer start];
    NSDictionary *files = [RequestMetadata(transfer) objectForKey:@"files"];
    NSDictionary *file = [[files allValues] objectAtIndex:0];
    Check([[file objectForKey:@"size"] unsignedIntegerValue] == [expected length],
          "clipboard reports UTF-8 byte length");
    Check([[[file objectForKey:@"preview"] dataUsingEncoding:NSUTF8StringEncoding] isEqual:expected],
          "clipboard preserves Unicode and snapshots the selected text");
    Check([[file objectForKey:@"fileType"] isEqual:@"text/plain"] &&
              [[file objectForKey:@"fileName"] isEqual:@"Clipboard.txt"],
          "clipboard metadata is unchanged");
    Check([[[transfer lastStatus] objectForKey:@"isActive"] boolValue] &&
              ![[[transfer lastStatus] objectForKey:@"isError"] boolValue],
          "request status is explicitly active");
    [transfer handleResponseData:[NSData data] statusCode:204];
    Check([[transfer recordedRequests] count] == 1 &&
              [[[transfer lastStatus] objectForKey:@"status"] isEqual:@"Clipboard sent."] &&
              ![[[transfer lastStatus] objectForKey:@"isActive"] boolValue] && CompletionSoundCount == 1,
          "204 completes clipboard once without upload");

    transfer = ClipboardTransfer(@"https://example.com/こんにちは");
    expected = [@"https://example.com/こんにちは" dataUsingEncoding:NSUTF8StringEncoding];
    [transfer start];
    files = [RequestMetadata(transfer) objectForKey:@"files"];
    [transfer handleResponseData:AcceptanceForFiles(files) statusCode:200];
    NSDictionary *upload = [[transfer recordedRequests] lastObject];
    Check([[transfer recordedRequests] count] == 2 && [[upload objectForKey:@"body"] isEqual:expected] &&
              [[upload objectForKey:@"path"] hasPrefix:@"/api/localsend/v2/upload?"],
          "accepted clipboard uploads the original UTF-8 bytes");
    [transfer handleResponseData:[NSData data] statusCode:200];
    Check([[[transfer lastStatus] objectForKey:@"status"] isEqual:@"Clipboard sent."] &&
              CompletionSoundCount == 2,
          "clipboard upload completes with one sound");

    for (NSString *invalidJSON in [NSArray arrayWithObjects:@"[]", @"{\"files\":[]}", @"invalid", nil]) {
        transfer = ClipboardTransfer(@"text");
        [transfer start];
        [transfer handleResponseData:[invalidJSON dataUsingEncoding:NSUTF8StringEncoding] statusCode:200];
        Check([[transfer recordedRequests] count] == 1 &&
                  [[[transfer lastStatus] objectForKey:@"isError"] boolValue],
              "malformed acceptance sends no upload and reports an explicit error");
    }
    transfer = ClipboardTransfer(@"");
    [transfer start];
    Check([[transfer recordedRequests] count] == 0 &&
              [[[transfer lastStatus] objectForKey:@"isError"] boolValue],
          "empty clipboard sends no request");
    transfer = ClipboardTransfer(@"text");
    [transfer start];
    [transfer handleResponseData:[NSData data] statusCode:403];
    Check([[transfer recordedRequests] count] == 1 && CompletionSoundCount == 2 &&
              ![[[transfer lastStatus] objectForKey:@"isActive"] boolValue],
          "declined clipboard stops without upload or completion sound");
}

static void TestPhotoBatch(void) {
    NSArray *payloads =
        [NSArray arrayWithObjects:[@"first original bytes" dataUsingEncoding:NSUTF8StringEncoding],
                                  [@"second original bytes" dataUsingEncoding:NSUTF8StringEncoding],
                                  [@"third original bytes" dataUsingEncoding:NSUTF8StringEncoding], nil];
    NSArray *assets =
        [NSArray arrayWithObjects:PhotoAsset([payloads objectAtIndex:0], @"first.jpg", NO),
                                  PhotoAsset([payloads objectAtIndex:1], @"second.png", NO),
                                  PhotoAsset([payloads objectAtIndex:2], @"third.gif", NO), nil];
    NSDictionary *device = [NSDictionary dictionaryWithObject:@"https" forKey:@"protocol"];
    ALAssetsLibrary *library = [[[ALAssetsLibrary alloc] init] autorelease];
    RecordingTransfer *transfer = [[[RecordingTransfer alloc] initWithDevice:device
                                                                 photoAssets:assets
                                                                     library:library] autorelease];
    Observe(transfer);
    [transfer start];
    NSDictionary *files = [RequestMetadata(transfer) objectForKey:@"files"];
    Check([files count] == 3, "one permission request contains every selected photo");
    [transfer handleResponseData:AcceptanceForFiles(files) statusCode:200];
    BOOL ordered = YES;
    BOOL stagedFilesRemoved = YES;
    NSUInteger index;
    for (index = 0; index < 3; index++) {
        WaitForRequestCount(transfer, index + 2);
        if ([[transfer recordedRequests] count] != index + 2) {
            ordered = NO;
            break;
        }
        NSDictionary *request = [[transfer recordedRequests] lastObject];
        NSString *temporaryPath = [request objectForKey:@"temporaryPath"];
        ordered = ordered && [[request objectForKey:@"body"] isEqual:[payloads objectAtIndex:index]] &&
                  [[request objectForKey:@"path"] hasPrefix:@"/api/localsend/v2/upload?sessionId=session"];
        [transfer handleResponseData:[NSData data] statusCode:200];
        stagedFilesRemoved =
            stagedFilesRemoved && ![[NSFileManager defaultManager] fileExistsAtPath:temporaryPath];
    }
    Check(ordered, "photos upload in selection order under the accepted session");
    Check(stagedFilesRemoved, "each temporary photo is removed after its upload");
    Check([[[transfer lastStatus] objectForKey:@"status"] isEqual:@"Sent 3 photos."] &&
              CompletionSoundCount == 3,
          "batch completion emits one sound and final status");

    transfer = [[[RecordingTransfer alloc] initWithDevice:device photoAssets:assets
                                                  library:library] autorelease];
    Observe(transfer);
    [transfer start];
    NSDictionary *incomplete = [NSDictionary
        dictionaryWithObjectsAndKeys:@"session", @"sessionId", [NSDictionary dictionary], @"files", nil];
    NSData *body = [NSJSONSerialization dataWithJSONObject:incomplete options:0 error:NULL];
    [transfer handleResponseData:body statusCode:200];
    Check([[transfer recordedRequests] count] == 1 &&
              [[[transfer lastStatus] objectForKey:@"isError"] boolValue],
          "a missing per-photo token rejects the entire batch before uploading");
}

static NSDictionary *ExportPhoto(NSData *data, BOOL shouldFail, BOOL cancel, NSUInteger *readCount) {
    ALAsset *asset = PhotoAsset(data, @"photo.jpg", shouldFail);
    RecordingTransfer *transfer = ClipboardTransfer(@"placeholder");
    [transfer setCaptureExportOnly:YES];
    if (cancel) {
        [transfer cancel];
    }
    NSDictionary *file = [NSDictionary
        dictionaryWithObjectsAndKeys:asset, @"asset", [NSNumber numberWithUnsignedInteger:[data length]],
                                     @"size", nil];
    [NSThread detachNewThreadSelector:@selector(preparePhotoFile:) toTarget:transfer withObject:file];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
    while ([transfer exportResult] == nil && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    *readCount = [[asset defaultRepresentation] testReadCount];
    return [transfer exportResult];
}

static void TestPhotoExport(void) {
    NSMutableData *payload = [NSMutableData dataWithLength:160001];
    NSUInteger index;
    for (index = 0; index < [payload length]; index++) {
        ((unsigned char *)[payload mutableBytes])[index] = (unsigned char)(index * 37);
    }
    NSUInteger readCount;
    NSDictionary *result = ExportPhoto(payload, NO, NO, &readCount);
    NSString *path = [result objectForKey:@"path"];
    Check([path length] > 0 && readCount >= 5 && [[NSData dataWithContentsOfFile:path] isEqual:payload],
          "photo export preserves 160001 original bytes using bounded reads");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    result = ExportPhoto(payload, YES, NO, &readCount);
    Check(result != nil && [[result objectForKey:@"path"] length] == 0 && readCount >= 2,
          "photo read error rejects the incomplete file");
    result = ExportPhoto(payload, NO, YES, &readCount);
    Check(result != nil && [[result objectForKey:@"path"] length] == 0 && readCount == 0,
          "cancelled photo export never reads asset data");
}

static void TestRedirect(void) {
    RecordingTransfer *transfer = ClipboardTransfer(@"text");
    [transfer start];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://other-device/"]];
    NSURLResponse *response = [[[NSURLResponse alloc] init] autorelease];
    Check([transfer connection:nil willSendRequest:request redirectResponse:nil] == request,
          "the original HTTP request is permitted");
    Check([transfer connection:nil willSendRequest:request redirectResponse:response] == nil &&
              [[[transfer lastStatus] objectForKey:@"isError"] boolValue],
          "HTTP redirects are rejected before following another endpoint");
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    TestClipboard();
    TestPhotoBatch();
    TestPhotoExport();
    TestRedirect();
    printf("%lu/%lu checks passed\n", (unsigned long)(TestCount - FailureCount), (unsigned long)TestCount);
    [pool drain];
    return FailureCount == 0 ? 0 : 1;
}
