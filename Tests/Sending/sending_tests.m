#import <Foundation/Foundation.h>
#import "LocalSendTransfer.h"
#import "LocalSendIdentityStore.h"
#import "LocalSendSounds.h"
#import "LocalSendDiscovery.h"

static NSUInteger CompletionSoundCount = 0;
static NSUInteger LiveExportTemporaries = 0;
static NSUInteger PeakExportTemporaries = 0;

NSString *const ALAssetPropertyType = @"ALAssetPropertyType";
NSString *const ALAssetTypePhoto = @"ALAssetTypePhoto";
NSString *const ALAssetTypeVideo = @"ALAssetTypeVideo";

@interface ExportReadTemporary : NSObject
@end

@implementation ExportReadTemporary
- (id)init {
    self = [super init];
    if (self) {
        LiveExportTemporaries++;
        PeakExportTemporaries = MAX(PeakExportTemporaries, LiveExportTemporaries);
    }
    return self;
}
- (void)dealloc {
    LiveExportTemporaries--;
    [super dealloc];
}
@end

@implementation LocalSendDiscovery
+ (NSString *)deviceName { return @"Test Device"; }
@end

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
- (NSString *)UTI {
    return _testUTI;
}
- (void)setTestUTI:(NSString *)type {
    [_testUTI release];
    _testUTI = [type copy];
}
- (void)setTestTracksTemporaries:(BOOL)value {
    _testTracksTemporaries = value;
}
- (long long)size {
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
    if (_testTracksTemporaries) {
        [[[ExportReadTemporary alloc] init] autorelease];
    }
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
    [_testUTI release];
    [super dealloc];
}
@end

@interface LegacyAssetRepresentation : ALAssetRepresentation
@end
@implementation LegacyAssetRepresentation
- (BOOL)respondsToSelector:(SEL)selector {
    return selector == @selector(filename) ? NO : [super respondsToSelector:selector];
}
- (NSString *)filename {
    [NSException raise:NSInvalidArgumentException format:@"filename is unavailable on iOS 4.x"];
    return nil;
}
@end

@interface SizedAssetRepresentation : ALAssetRepresentation {
    long long _reportedSize;
}
- (void)setReportedSize:(long long)size;
@end
@implementation SizedAssetRepresentation
- (void)setReportedSize:(long long)size { _reportedSize = size; }
- (long long)size { return _reportedSize; }
@end

@implementation ALAsset
- (id)initWithRepresentation:(ALAssetRepresentation *)representation {
    self = [super init];
    if (self) {
        _testRepresentation = [representation retain];
        _testType = [ALAssetTypePhoto copy];
    }
    return self;
}
- (ALAssetRepresentation *)defaultRepresentation {
    return _testRepresentation;
}
- (id)valueForProperty:(NSString *)property {
    return [property isEqual:ALAssetPropertyType] ? _testType : nil;
}
- (void)setTestType:(NSString *)type {
    [_testType release];
    _testType = [type copy];
}
- (void)dealloc {
    [_testRepresentation release];
    [_testType release];
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

static void TestVideoBatch(void) {
    NSData *movie = [@"original movie bytes" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *image = [@"original image bytes" dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *assets = [NSArray arrayWithObjects:PhotoAsset(movie, @"clip.MOV", NO),
                                                 PhotoAsset(image, @"image.JPG", NO), nil];
    NSDictionary *device = [NSDictionary dictionaryWithObject:@"https" forKey:@"protocol"];
    ALAssetsLibrary *library = [[[ALAssetsLibrary alloc] init] autorelease];
    RecordingTransfer *transfer = [[[RecordingTransfer alloc] initWithDevice:device
                                                                 photoAssets:assets library:library] autorelease];
    Observe(transfer);
    [transfer start];
    NSDictionary *files = [RequestMetadata(transfer) objectForKey:@"files"];
    BOOL hasVideo = NO;
    BOOL hasPhoto = NO;
    for (NSDictionary *file in [files allValues]) {
        hasVideo |= [[file objectForKey:@"fileName"] isEqual:@"clip.MOV"] &&
                    [[file objectForKey:@"fileType"] isEqual:@"video/quicktime"] &&
                    [[file objectForKey:@"size"] unsignedIntegerValue] == [movie length];
        hasPhoto |= [[file objectForKey:@"fileName"] isEqual:@"image.JPG"] &&
                    [[file objectForKey:@"fileType"] isEqual:@"image/jpeg"];
    }
    Check([files count] == 2 && hasVideo && hasPhoto, "mixed batch advertises original video and photo metadata");
    [transfer handleResponseData:AcceptanceForFiles(files) statusCode:200];
    WaitForRequestCount(transfer, 2);
    BOOL firstSent = [[[transfer recordedRequests] lastObject][@"body"] isEqual:movie];
    [transfer handleResponseData:[NSData data] statusCode:200];
    WaitForRequestCount(transfer, 3);
    BOOL secondSent = [[[transfer recordedRequests] lastObject][@"body"] isEqual:image];
    [transfer handleResponseData:[NSData data] statusCode:200];
    Check(firstSent && secondSent && [[[transfer lastStatus] objectForKey:@"status"] isEqual:@"Sent 2 items."],
          "mixed batch uploads original bytes in selection order");
}

static RecordingTransfer *TransferForRepresentation(ALAssetRepresentation *representation,
                                                     NSString *assetType) {
    ALAsset *asset = [[[ALAsset alloc] initWithRepresentation:representation] autorelease];
    [asset setTestType:assetType];
    RecordingTransfer *transfer = [[[RecordingTransfer alloc]
        initWithDevice:[NSDictionary dictionaryWithObject:@"https" forKey:@"protocol"]
            photoAssets:[NSArray arrayWithObject:asset]
                library:[[[ALAssetsLibrary alloc] init] autorelease]] autorelease];
    Observe(transfer);
    return transfer;
}

static void TestLegacyAssetMetadata(void) {
    NSArray *types = [NSArray arrayWithObjects:@"public.jpeg", @"public.png", @"com.apple.quicktime-movie",
                                               @"public.mpeg-4", @"com.example.unknown-media", nil];
    NSArray *extensions = [NSArray arrayWithObjects:@"jpeg", @"png", @"mov", @"mp4", @"", nil];
    NSArray *mimeTypes = [NSArray arrayWithObjects:@"image/jpeg", @"image/png", @"video/quicktime",
                                                  @"video/mp4", @"application/octet-stream", nil];
    for (NSUInteger index = 0; index < [types count]; index++) {
        LegacyAssetRepresentation *representation = [[[LegacyAssetRepresentation alloc]
            initWithData:[@"original data" dataUsingEncoding:NSUTF8StringEncoding]
                fileName:nil fail:NO] autorelease];
        [representation setTestUTI:[types objectAtIndex:index]];
        BOOL isVideo = index == 2 || index == 3;
        RecordingTransfer *transfer = TransferForRepresentation(representation,
                                                isVideo ? ALAssetTypeVideo : ALAssetTypePhoto);
        [transfer start];
        NSDictionary *metadata = [[[[RequestMetadata(transfer) objectForKey:@"files"] allValues]
                                   objectAtIndex:0] retain];
        NSString *name = [metadata objectForKey:@"fileName"];
        NSString *extension = [name pathExtension];
        BOOL correctExtension = [extension isEqual:[extensions objectAtIndex:index]] ||
                                (index == 0 && [extension isEqual:@"jpg"]);
        if (!correctExtension || ![[metadata objectForKey:@"fileType"] isEqual:[mimeTypes objectAtIndex:index]]) {
            NSLog(@"Unexpected legacy metadata for %@: %@", [types objectAtIndex:index], metadata);
        }
        Check([name hasPrefix:isVideo ? @"Video-" : @"Photo-"] && correctExtension &&
                  [[metadata objectForKey:@"fileType"] isEqual:[mimeTypes objectAtIndex:index]],
              "iOS 4 asset metadata uses available UTI without invoking filename");
        [metadata release];
    }

    SizedAssetRepresentation *representation = [[[SizedAssetRepresentation alloc]
        initWithData:[NSData data] fileName:@"large.mov" fail:NO] autorelease];
    long long largeSize = 5LL * 1024 * 1024 * 1024 + 17;
    [representation setReportedSize:largeSize];
    RecordingTransfer *transfer = TransferForRepresentation(representation, ALAssetTypeVideo);
    [transfer start];
    NSDictionary *metadata = [[[RequestMetadata(transfer) objectForKey:@"files"] allValues] objectAtIndex:0];
    Check([[metadata objectForKey:@"fileName"] isEqual:@"large.mov"] &&
              [[metadata objectForKey:@"size"] longLongValue] == largeSize,
          "modern filenames are preserved and asset metadata retains 64-bit size");

    [representation setReportedSize:-1];
    transfer = TransferForRepresentation(representation, ALAssetTypeVideo);
    [transfer start];
    Check([[transfer recordedRequests] count] == 0 &&
              [[[transfer lastStatus] objectForKey:@"isError"] boolValue],
          "negative asset sizes fail safely before contacting the receiver");
}

static NSDictionary *ExportPhoto(NSData *data, BOOL shouldFail, BOOL cancel, BOOL trackTemporaries,
                                 NSUInteger *readCount) {
    ALAsset *asset = PhotoAsset(data, @"photo.jpg", shouldFail);
    [[asset defaultRepresentation] setTestTracksTemporaries:trackTemporaries];
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
    NSDictionary *result = ExportPhoto(payload, NO, NO, NO, &readCount);
    NSString *path = [result objectForKey:@"path"];
    Check([path length] > 0 && readCount >= 5 && [[NSData dataWithContentsOfFile:path] isEqual:payload],
          "photo export preserves 160001 original bytes using bounded reads");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    result = ExportPhoto(payload, YES, NO, NO, &readCount);
    Check(result != nil && [[result objectForKey:@"path"] length] == 0 && readCount >= 2,
          "photo read error rejects the incomplete file");
    result = ExportPhoto(payload, NO, YES, NO, &readCount);
    Check(result != nil && [[result objectForKey:@"path"] length] == 0 && readCount == 0,
          "cancelled photo export never reads asset data");

    PeakExportTemporaries = 0;
    result = ExportPhoto([NSMutableData dataWithLength:4 * 1024 * 1024], NO, NO, YES, &readCount);
    path = [result objectForKey:@"path"];
    Check([path length] > 0 && readCount >= 128 && PeakExportTemporaries == 1 &&
              LiveExportTemporaries == 0,
          "large asset export releases framework temporaries between chunks");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
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
    TestVideoBatch();
    TestLegacyAssetMetadata();
    TestPhotoExport();
    TestRedirect();
    printf("%lu/%lu checks passed\n", (unsigned long)(TestCount - FailureCount), (unsigned long)TestCount);
    [pool drain];
    return FailureCount == 0 ? 0 : 1;
}
