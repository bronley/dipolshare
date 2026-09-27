#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <pthread.h>

static NSString *testRunDirectory;
static NSString *testRootDirectory;
static NSArray *TestSearchDirectories(NSSearchPathDirectory directory, NSSearchPathDomainMask domain,
                                      BOOL expand) {
    NSString *name = directory == NSDocumentDirectory ? @"Documents"
                     : directory == NSCachesDirectory ? @"Caches"
                                                      : @"ApplicationSupport";
    return [NSArray arrayWithObject:[testRootDirectory stringByAppendingPathComponent:name]];
}
#define NSSearchPathForDirectoriesInDomains TestSearchDirectories
#import "LocalSendReceivedFileStore.m"
#import "LocalSendReceiver.m"
#undef NSSearchPathForDirectoriesInDomains

static int checks, failures;
static void Check(BOOL condition, NSString *label) {
    checks++;
    printf("%s %s\n", condition ? "PASS" : "FAIL", [label UTF8String]);
    if (!condition) {
        failures++;
    }
}
static void Pump(void) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
}
@interface TestReceiver : LocalSendReceiver {
  @public
    BOOL noSpace;
}
@end
@implementation TestReceiver
- (BOOL)hasSpaceLocked:(unsigned long long)size {
    return !noSpace;
}
@end

static NSDictionary *Peer(void) {
    return @{
        @"protocol" : @"https",
        @"address" : @"192.0.2.10",
        @"fingerprint" : @"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    };
}
static NSDictionary *File(NSString *fileId, NSString *name, unsigned long long size, NSString *hash) {
    NSMutableDictionary *file = [NSMutableDictionary
        dictionaryWithObjectsAndKeys:fileId, @"id", name, @"fileName", @"application/octet-stream",
                                     @"fileType", @(size), @"size", nil];
    if (hash != nil) {
        [file setObject:hash forKey:@"sha256"];
    }
    return file;
}
static NSDictionary *Payload(NSDictionary *files) {
    return @{@"info" : @{@"alias" : @"Test sender"}, @"files" : files};
}
static NSDictionary *Request(LocalSendReceiver *receiver, NSString *target, NSDictionary *payload,
                             NSDictionary *peer) {
    NSData *body = payload == nil ? [NSData data]
                                  : [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    return [receiver receiveServer:nil
                 responseForMethod:@"POST"
                            target:target
                           headers:@{}
                              body:body
                              peer:peer];
}
static NSInteger Status(NSDictionary *response) {
    return [[response objectForKey:@"status"] integerValue];
}

@interface TestConnectionServer : NSObject {
    BOOL _open;
}
- (void)setOpen:(BOOL)value;
- (BOOL)isCurrentConnectionOpen;
@end
@implementation TestConnectionServer
- (id)init {
    if ((self = [super init])) {
        _open = YES;
    }
    return self;
}
- (void)setOpen:(BOOL)value {
    @synchronized(self) {
        _open = value;
    }
}
- (BOOL)isCurrentConnectionOpen {
    @synchronized(self) {
        return _open;
    }
}
@end

@interface PrepareTask : NSObject {
  @public
    LocalSendReceiver *receiver;
    NSDictionary *payload, *peer, *response;
    NSCondition *lock;
    BOOL done;
    pthread_t thread;
    id server;
}
- (id)initWithReceiver:(LocalSendReceiver *)value payload:(NSDictionary *)body peer:(NSDictionary *)origin;
- (id)initWithReceiver:(LocalSendReceiver *)value
               payload:(NSDictionary *)body
                  peer:(NSDictionary *)origin
                server:(id)connectionServer;
- (void)run;
@end
static void *RunPrepare(void *object) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [(PrepareTask *)object run];
    [pool drain];
    return NULL;
}
@implementation PrepareTask
- (id)initWithReceiver:(LocalSendReceiver *)value payload:(NSDictionary *)body peer:(NSDictionary *)origin {
    return [self initWithReceiver:value payload:body peer:origin server:nil];
}
- (id)initWithReceiver:(LocalSendReceiver *)value
               payload:(NSDictionary *)body
                  peer:(NSDictionary *)origin
                server:(id)connectionServer {
    if ((self = [super init])) {
        receiver = [value retain];
        payload = [body copy];
        peer = [origin copy];
        lock = [[NSCondition alloc] init];
        server = [connectionServer retain];
        if (pthread_create(&thread, NULL, RunPrepare, self) != 0) {
            abort();
        }
    }
    return self;
}
- (void)run {
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    NSDictionary *result = [receiver receiveServer:server
                                 responseForMethod:@"POST"
                                            target:@"/api/localsend/v2/prepare-upload"
                                           headers:@{}
                                              body:body
                                              peer:peer];
    [lock lock];
    response = [result retain];
    done = YES;
    [lock broadcast];
    [lock unlock];
}
- (void)dealloc {
    [receiver release];
    [payload release];
    [peer release];
    [response release];
    [lock release];
    [server release];
    [super dealloc];
}
@end
static NSDictionary *Pending(PrepareTask *task) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    NSDictionary *request;
    while ((request = [task->receiver pendingRequest]) == nil && [deadline timeIntervalSinceNow] > 0) {
        [task->lock lock];
        BOOL done = task->done;
        [task->lock unlock];
        if (done) {
            break;
        }
        Pump();
    }
    if (request == nil) {
        printf("FATAL: prepare did not become pending\n");
        exit(2);
    }
    return request;
}
static NSDictionary *Join(PrepareTask *task) {
    [task->lock lock];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!task->done && [task->lock waitUntilDate:deadline]) {
    }
    if (!task->done) {
        printf("FATAL: prepare worker did not finish\n");
        exit(2);
    }
    [task->lock unlock];
    pthread_join(task->thread, NULL);
    NSDictionary *result = [[task->response retain] autorelease];
    [task release];
    Pump();
    return result;
}
static NSDictionary *Accept(LocalSendReceiver *receiver, NSDictionary *files) {
    PrepareTask *task = [[PrepareTask alloc] initWithReceiver:receiver payload:Payload(files) peer:Peer()];
    NSDictionary *pending = Pending(task);
    [receiver respondToRequest:[pending objectForKey:@"requestId"] accept:YES];
    NSDictionary *response = Join(task);
    if (Status(response) != 200) {
        printf("FATAL: acceptance returned %ld\n", (long)Status(response));
        exit(2);
    }
    return [NSJSONSerialization JSONObjectWithData:[response objectForKey:@"body"] options:0 error:NULL];
}
static NSString *Target(NSDictionary *session, NSString *fileId) {
    return [NSString stringWithFormat:@"/api/localsend/v2/upload?sessionId=%@&fileId=%@&token=%@",
                                      session[@"sessionId"], fileId, session[@"files"][fileId]];
}
static id Begin(LocalSendReceiver *receiver, NSDictionary *session, NSString *fileId, NSString *length,
                NSInteger *status) {
    return [receiver receiveServer:nil
               beginUploadToTarget:Target(session, fileId)
                           headers:length ? @{@"content-length" : length} : @{}
                              peer:Peer()
                       errorStatus:status];
}
static NSString *Hash(NSData *data) {
    unsigned char hash[32];
    CC_SHA256([data bytes], (CC_LONG)[data length], hash);
    NSMutableString *value = [NSMutableString string];
    for (int i = 0; i < 32; i++) {
        [value appendFormat:@"%02x", hash[i]];
    }
    return value;
}
static NSUInteger StagedCount(void) {
    return [[[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:[testRootDirectory
                                      stringByAppendingPathComponent:@"Caches/LocalSendIncoming"]
                            error:NULL] count];
}
static TestReceiver *Receiver(NSString *suite) {
    testRootDirectory = [testRunDirectory stringByAppendingPathComponent:suite];
    [[NSFileManager defaultManager] removeItemAtPath:testRootDirectory error:NULL];
    TestReceiver *receiver = [[[TestReceiver alloc] init] autorelease];
    [receiver setLocalInfo:@{@"alias" : @"Receiver", @"fingerprint" : @"receiver"}];
    return receiver;
}

int main(int argc, const char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (argc != 2) {
        fprintf(stderr, "Usage: receiver_tests TEMPORARY_DIRECTORY\n");
        return 2;
    }
    testRunDirectory = [NSString stringWithUTF8String:argv[1]];
    TestReceiver *r = Receiver(@"primary");
    NSDictionary *peer = Peer();
    NSInteger status;
    NSData *abc = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *files = @{@"one" : File(@"one", @"hello.txt", 3, nil)};
    PrepareTask *task = [[PrepareTask alloc] initWithReceiver:r payload:Payload(files) peer:peer];
    NSDictionary *pending = Pending(task);
    Check([pending[@"senderAlias"] isEqual:@"Test sender"] &&
              [pending[@"totalBytes"] unsignedLongLongValue] == 3,
          @"prepare exposes correct approval metadata");
    Check(Status(Request(r, @"/api/localsend/v2/prepare-upload", Payload(files), peer)) == 409,
          @"pending request occupies session slot");
    [r respondToRequest:@"stale-id" accept:YES];
    Check([r pendingRequest] != nil, @"stale approval cannot accept pending request");
    [r respondToRequest:pending[@"requestId"] accept:NO];
    Check(Status(Join(task)) == 403 && [r pendingRequest] == nil, @"decline returns403 and releases slot");

    NSDictionary *session = Accept(r, files);
    Check([session[@"sessionId"] length] == 64 && [session[@"files"][@"one"] length] == 64 &&
              ![session[@"sessionId"] isEqual:session[@"files"][@"one"]],
          @"independent random session and file tokens");
    Check(Status(Request(r, @"/api/localsend/v2/prepare-upload", Payload(files), peer)) == 409,
          @"accepted request occupies session slot");
    NSMutableDictionary *wrong = [[peer mutableCopy] autorelease];
    wrong[@"address"] = @"192.0.2.99";
    id upload = [r receiveServer:nil
             beginUploadToTarget:Target(session, @"one")
                         headers:@{}
                            peer:wrong
                     errorStatus:&status];
    Check(upload == nil && status == 403, @"wrong sender IP cannot upload");
    wrong[@"address"] = peer[@"address"];
    wrong[@"fingerprint"] = @"other";
    upload = [r receiveServer:nil
          beginUploadToTarget:Target(session, @"one")
                      headers:@{}
                         peer:wrong
                  errorStatus:&status];
    Check(upload == nil && status == 403, @"wrong certificate cannot upload");
    upload = [r receiveServer:nil
          beginUploadToTarget:[Target(session, @"one") stringByAppendingString:@"x"]
                      headers:@{}
                         peer:peer
                  errorStatus:&status];
    Check(upload == nil && status == 403, @"wrong token cannot upload");
    NSString *wrongSession =
        [Target(session, @"one") stringByReplacingOccurrencesOfString:session[@"sessionId"]
                                                           withString:@"wrong-session"];
    upload = [r receiveServer:nil beginUploadToTarget:wrongSession headers:@{} peer:peer errorStatus:&status];
    Check(upload == nil && status == 403, @"wrong session ID cannot upload");
    upload = [r receiveServer:nil
          beginUploadToTarget:[Target(session, @"one") stringByAppendingString:@"&fileId=one"]
                      headers:@{}
                         peer:peer
                  errorStatus:&status];
    Check(upload == nil && status == 400, @"duplicate query parameters rejected");
    upload = Begin(r, session, @"one", @"2", &status);
    Check(upload == nil && status == 400, @"mismatching Content-Length rejected before opening file");
    upload = [Begin(r, session, @"one", @"3", &status) retain];
    Check(upload != nil && status == 200 && StagedCount() == 1, @"authenticated upload begins staging");
    id duplicate = Begin(r, session, @"one", @"3", &status);
    Check(duplicate == nil && status == 409, @"simultaneous duplicate upload rejected");
    Check([r receiveServer:nil upload:upload appendData:[abc subdataWithRange:NSMakeRange(0, 1)]] &&
              [r receiveServer:nil upload:upload appendData:[abc subdataWithRange:NSMakeRange(1, 2)]],
          @"segmented body writes succeed");
    Check([r receiveServer:nil finishUpload:upload] == 200, @"exact length file finishes");
    [upload release];
    NSDictionary *saved = [[r receivedFiles] lastObject];
    Check([[NSData dataWithContentsOfFile:saved[@"path"]] isEqual:abc] && StagedCount() == 0,
          @"saved content exact and staging cleaned");
    Check([r unseenReceivedFileCount] == 1, @"completed file is unseen until Received opens");
    upload = Begin(r, session, @"one", @"3", &status);
    Check(upload == nil && status == 403, @"completed session token cannot replay");
    TestReceiver *reopened = [[[TestReceiver alloc] init] autorelease];
    Check([[reopened receivedFiles] count] == 1 &&
              [[[reopened receivedFiles] lastObject][@"name"] isEqual:@"hello.txt"],
          @"received index and file survive receiver recreation");
    Check([reopened unseenReceivedFileCount] == 1, @"unseen badge count survives receiver recreation");
    Check([r markReceivedFilesSeen] && [r unseenReceivedFileCount] == 0,
          @"opening Received clears the unseen count");
    TestReceiver *seenAgain = [[[TestReceiver alloc] init] autorelease];
    Check([seenAgain unseenReceivedFileCount] == 0, @"seen state survives receiver recreation");

    NSArray *unsafe = @[
        @"../escape", @"/absolute", @"folder/file", @"folder\\file", @"..", @".hidden", @"C:drive",
        @"bad\nname"
    ];
    for (NSString *name in unsafe) {
        Check(Status(Request(r, @"/api/localsend/v2/prepare-upload",
                             Payload(@{@"one" : File(@"one", name, 0, nil)}), peer)) == 400,
              [@"unsafe filename rejected: "
                  stringByAppendingString:[name stringByReplacingOccurrencesOfString:@"\n"
                                                                          withString:@"\\n"]]);
    }
    NSMutableDictionary *badFile = [[File(@"one", @"x", 0, nil) mutableCopy] autorelease];
    for (id badSize in @[ @(-1), @0.5, @YES, @68719476737ULL, @"2" ]) {
        badFile[@"size"] = badSize;
        Check(Status(Request(r, @"/api/localsend/v2/prepare-upload", Payload(@{@"one" : badFile}), peer)) ==
                  400,
              [NSString stringWithFormat:@"invalid metadata size rejected: %@", badSize]);
    }
    Check(Status(Request(r, @"/api/localsend/v2/prepare-upload", Payload(@{}), peer)) == 400,
          @"empty offer rejected");
    Check(Status(Request(r, @"/api/localsend/v2/prepare-upload",
                         Payload(@{@"one" : File(@"one", @"x", 1, @"bad")}), peer)) == 400,
          @"malformed SHA256 rejected");
    wrong[@"protocol"] = @"http";
    Check(Status(Request(r, @"/api/localsend/v2/prepare-upload", Payload(files), wrong)) == 426,
          @"plaintext receive request rejected");

    session = Accept(r, @{@"one" : File(@"one", @"empty", 0, nil)});
    upload = [Begin(r, session, @"one", @"0", &status) retain];
    Check(upload != nil && [r receiveServer:nil finishUpload:upload] == 200, @"zero-byte file completes");
    [upload release];

    session = Accept(r, files);
    upload = [Begin(r, session, @"one", @"3", &status) retain];
    [r receiveServer:nil upload:upload appendData:[NSData dataWithBytes:"ab" length:2]];
    Check([r receiveServer:nil finishUpload:upload] == 400 && StagedCount() == 0,
          @"truncated body rejected and partial removed");
    [upload release];
    session = Accept(r, files);
    upload = [Begin(r, session, @"one", nil, &status) retain];
    Check(![r receiveServer:nil upload:upload appendData:[NSData dataWithBytes:"abcd" length:4]] &&
              StagedCount() == 0,
          @"oversized stream rejected and partial removed");
    [upload release];

    session = Accept(r, @{@"one" : File(@"one", @"hashed", 3, Hash(abc))});
    upload = [Begin(r, session, @"one", @"3", &status) retain];
    [r receiveServer:nil upload:upload appendData:[NSData dataWithBytes:"bad" length:3]];
    Check([r receiveServer:nil finishUpload:upload] == 422 && StagedCount() == 0,
          @"SHA256 mismatch returns422 without saving");
    [upload release];
    upload = [Begin(r, session, @"one", @"3", &status) retain];
    Check(upload != nil && [r receiveServer:nil upload:upload appendData:abc] &&
              [r receiveServer:nil finishUpload:upload] == 200,
          @"checksum retry uses same credentials and succeeds");
    [upload release];
    session = Accept(r, @{@"one" : File(@"one", @"hashed-again", 3, Hash(abc))});
    BOOL mismatchRetries = YES;
    for (int i = 0; i < 3; i++) {
        upload = [Begin(r, session, @"one", @"3", &status) retain];
        mismatchRetries &= upload != nil;
        [r receiveServer:nil upload:upload appendData:[NSData dataWithBytes:"bad" length:3]];
        mismatchRetries &= [r receiveServer:nil finishUpload:upload] == 422;
        [upload release];
    }
    Check(mismatchRetries && Begin(r, session, @"one", @"3", &status) == nil && StagedCount() == 0,
          @"checksum retry limit stops after three failures");

    task = [[PrepareTask alloc] initWithReceiver:r payload:Payload(files) peer:peer];
    Pending(task);
    Check(Status(Request(r, @"/api/localsend/v2/cancel", nil, peer)) == 200 && Status(Join(task)) == 403,
          @"pending sender can cancel without unknown session ID");
    task = [[PrepareTask alloc] initWithReceiver:r payload:Payload(files) peer:peer];
    Pending(task);
    Check(Status(Request(r, @"/api/localsend/v2/cancel?sessionId=wrong", nil, peer)) == 403 &&
              [r pendingRequest] != nil,
          @"wrong ID cannot cancel pending request");
    [r cancelCurrentTransfer];
    Check(Status(Join(task)) == 403, @"local cancellation releases pending worker");
    TestConnectionServer *connection = [[[TestConnectionServer alloc] init] autorelease];
    task = [[PrepareTask alloc] initWithReceiver:r payload:Payload(files) peer:peer server:connection];
    Pending(task);
    NSDate *disconnectedAt = [NSDate date];
    [connection setOpen:NO];
    Check(Status(Join(task)) == 403 && [r pendingRequest] == nil &&
              -[disconnectedAt timeIntervalSinceNow] < 2.0,
          @"abrupt sender EOF clears pending approval within two seconds");
    [connection setOpen:YES];
    PrepareTask *oldTask = [[PrepareTask alloc] initWithReceiver:r
                                                         payload:Payload(files)
                                                            peer:peer
                                                          server:connection];
    Pending(oldTask);
    [r cancelCurrentTransfer];
    [connection setOpen:NO];
    task = [[PrepareTask alloc] initWithReceiver:r payload:Payload(files) peer:peer];
    pending = Pending(task);
    NSString *replacementId = [[pending[@"requestId"] copy] autorelease];
    Check(Status(Join(oldTask)) == 403 &&
              [[[r pendingRequest] objectForKey:@"requestId"] isEqual:replacementId],
          @"aborted old prepare worker preserves replacement pending session");
    [r respondToRequest:replacementId accept:NO];
    Check(Status(Join(task)) == 403, @"replacement session responds normally after old EOF");
    session = Accept(r, files);
    upload = [Begin(r, session, @"one", @"3", &status) retain];
    [r receiveServer:nil upload:upload appendData:[NSData dataWithBytes:"a" length:1]];
    Check(Status(Request(r, @"/api/localsend/v2/cancel", nil, peer)) == 403,
          @"accepted session requires cancellation ID");
    NSString *cancel = [@"/api/localsend/v2/cancel?sessionId=" stringByAppendingString:session[@"sessionId"]];
    Check(Status(Request(r, cancel, nil, peer)) == 200 && StagedCount() == 0 &&
              ![r receiveServer:nil upload:upload appendData:abc],
          @"authenticated cancellation closes active upload");
    NSDictionary *newSession = Accept(r, files);
    [r receiveServer:nil abortUpload:upload];
    [upload release];
    upload = [Begin(r, newSession, @"one", @"3", &status) retain];
    Check(upload != nil, @"stale aborted worker cannot cancel newer session");
    [r cancelCurrentTransfer];
    [upload release];

    session = Accept(r, @{@"a" : File(@"a", @"same.txt", 3, nil), @"b" : File(@"b", @"same.txt", 3, nil)});
    id a = [Begin(r, session, @"a", @"3", &status) retain],
       b = [Begin(r, session, @"b", @"3", &status) retain];
    BOOL multi = a != nil && b != nil && [r receiveServer:nil upload:a appendData:abc] &&
                 [r receiveServer:nil upload:b appendData:[NSData dataWithBytes:"def" length:3]];
    multi &= [r receiveServer:nil finishUpload:b] == 200;
    multi &= [r receiveServer:nil finishUpload:a] == 200;
    NSArray *history = [r receivedFiles];
    Check(multi && ![history[0][@"path"] isEqual:history[1][@"path"]] &&
              [[NSData dataWithContentsOfFile:history[0][@"path"]] isEqual:abc] &&
              [[NSData dataWithContentsOfFile:history[1][@"path"]] isEqual:[NSData dataWithBytes:"def"
                                                                                          length:3]],
          @"concurrent same-name files saved separately with exact content");
    [a release];
    [b release];

    unsigned long long large = 4294967296ULL + 123;
    task = [[PrepareTask alloc] initWithReceiver:r
                                         payload:Payload(@{@"one" : File(@"one", @"large", large, nil)})
                                            peer:peer];
    pending = Pending(task);
    Check([pending[@"totalBytes"] unsignedLongLongValue] == large, @"metadata preserves sizes beyond32bit");
    [r respondToRequest:pending[@"requestId"] accept:YES];
    NSDictionary *response = Join(task);
    session = [NSJSONSerialization JSONObjectWithData:response[@"body"] options:0 error:NULL];
    upload = [Begin(r, session, @"one", [NSString stringWithFormat:@"%llu", large], &status) retain];
    Check(upload != nil && ((LocalSendIncomingUpload *)upload)->expectedByteCount == large,
          @"upload expected-byte counter preserves64bit size");
    [r cancelCurrentTransfer];
    [upload release];

    r->noSpace = YES;
    Check(Status(Request(r, @"/api/localsend/v2/prepare-upload", Payload(files), peer)) == 507,
          @"insufficient storage rejects offer");
    r->noSpace = NO;
    task = [[PrepareTask alloc] initWithReceiver:r payload:Payload(files) peer:peer];
    pending = Pending(task);
    r->noSpace = YES;
    [r respondToRequest:pending[@"requestId"] accept:YES];
    Check(Status(Join(task)) == 403, @"storage rechecked at approval");
    r->noSpace = NO;
    session = Accept(r, files);
    r->noSpace = YES;
    Check(Begin(r, session, @"one", @"3", &status) == nil && status == 507,
          @"storage rechecked before upload");
    r->noSpace = NO;
    [r cancelCurrentTransfer];
    session = Accept(r, files);
    upload = [Begin(r, session, @"one", @"3", &status) retain];
    [r stop];
    Check(StagedCount() == 0 && ![r receiveServer:nil upload:upload appendData:abc] &&
              Status(Request(r, @"/api/localsend/v2/prepare-upload", Payload(files), peer)) == 503,
          @"stop interrupts and cleans upload; rejects new offers");
    [upload release];
    NSUInteger preserved = [[r receivedFiles] count];
    Check(preserved == 5, @"cancel/failure/stop preserve all five completed files");

    r = Receiver(@"storage-failure");
    session = Accept(r, files);
    upload = [Begin(r, session, @"one", @"3", &status) retain];
    [r receiveServer:nil upload:upload appendData:abc];
    [[NSFileManager defaultManager]
        removeItemAtPath:[testRootDirectory stringByAppendingPathComponent:@"Documents/Received"]
                   error:NULL];
    Check([r receiveServer:nil finishUpload:upload] == 507 && [[r receivedFiles] count] == 0 &&
              StagedCount() == 0,
          @"destination disappearance fails cleanly without publishing file");
    [upload release];
    r = Receiver(@"index-failure");
    session = Accept(r, files);
    upload = [Begin(r, session, @"one", @"3", &status) retain];
    [r receiveServer:nil upload:upload appendData:abc];
    [[NSFileManager defaultManager]
              createDirectoryAtPath:[testRootDirectory stringByAppendingPathComponent:
                                                           @"ApplicationSupport/LocalSendReceived.plist"]
        withIntermediateDirectories:NO
                         attributes:nil
                              error:NULL];
    Check([r receiveServer:nil finishUpload:upload] == 507 && [[r receivedFiles] count] == 0 &&
              StagedCount() == 0 &&
              [[[NSFileManager defaultManager]
                  contentsOfDirectoryAtPath:[testRootDirectory
                                                stringByAppendingPathComponent:@"Documents/Received"]
                                      error:NULL] count] == 0,
          @"index write failure rolls back new final file and staging");
    [upload release];
    r = Receiver(@"startup-cleanup");
    NSString *orphan =
        [testRootDirectory stringByAppendingPathComponent:@"Caches/LocalSendIncoming/orphan.part"];
    [abc writeToFile:orphan atomically:NO];
    TestReceiver *cleaned = [[[TestReceiver alloc] init] autorelease];
    Check(cleaned != nil && StagedCount() == 0, @"startup cleans only app-owned abandoned staging files");

    // A three-photo offer has one approval, independent upload tokens, and
    // three persisted files even when two source filenames are identical.
    r = Receiver(@"three-photos");
    NSData *photoA = [NSData dataWithBytes:"\xff\xd8\x01\xff\xd9" length:5];
    NSData *photoB = [NSData dataWithBytes:"\xff\xd8\x02\xff\xd9" length:5];
    NSData *photoC = [NSData dataWithBytes:"\x89PNG\r\n" length:6];
    NSDictionary *photoFiles = @{
        @"p1" : File(@"p1", @"IMG_0001.JPG", 5, Hash(photoA)),
        @"p2" : File(@"p2", @"IMG_0001.JPG", 5, Hash(photoB)),
        @"p3" : File(@"p3", @"IMG_0003.PNG", 6, Hash(photoC))
    };
    task = [[PrepareTask alloc] initWithReceiver:r payload:Payload(photoFiles) peer:peer];
    pending = Pending(task);
    Check([pending[@"files"] count] == 3 && [pending[@"totalBytes"] unsignedLongLongValue] == 16,
          @"three photos appear in one approval with correct total size");
    [r respondToRequest:pending[@"requestId"] accept:YES];
    session = [NSJSONSerialization JSONObjectWithData:[Join(task) objectForKey:@"body"] options:0 error:NULL];
    Check([session[@"files"] count] == 3 && ![session[@"files"][@"p1"] isEqual:session[@"files"][@"p2"]],
          @"three photos get independent upload tokens");
    NSArray *ids = @[ @"p1", @"p2", @"p3" ];
    NSArray *contents = @[ photoA, photoB, photoC ];
    BOOL allPhotos = YES;
    for (NSUInteger i = 0; i < [ids count]; i++) {
        NSString *photoId = ids[i];
        NSData *content = contents[i];
        upload = [Begin(r, session, photoId,
                        [NSString stringWithFormat:@"%lu", (unsigned long)[content length]], &status) retain];
        allPhotos &= upload != nil && status == 200;
        if (upload != nil) {
            allPhotos &= [r receiveServer:nil upload:upload appendData:content];
            allPhotos &= [r receiveServer:nil finishUpload:upload] == 200;
            [upload release];
        }
        if (i < 2) {
            allPhotos &= [[r receivedFiles] count] == i + 1;
        }
    }
    NSArray *received = [r receivedFiles];
    Check(allPhotos && [received count] == 3 && StagedCount() == 0 &&
              ![received[1][@"path"] isEqual:received[2][@"path"]] &&
              [[NSData dataWithContentsOfFile:received[2][@"path"]] isEqual:photoA] &&
              [[NSData dataWithContentsOfFile:received[1][@"path"]] isEqual:photoB] &&
              [[NSData dataWithContentsOfFile:received[0][@"path"]] isEqual:photoC],
          @"three original photo payloads persist separately with identical names allowed");
    TestReceiver *reloaded = [[[TestReceiver alloc] init] autorelease];
    Check([[reloaded receivedFiles] count] == 3, @"all three photos survive receiver restart");
    Pump();
    printf("RESULT %d checks, %d failures\n", checks, failures);
    [pool drain];
    return failures ? 1 : 0;
}
