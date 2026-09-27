#import "LocalSendJSON.h"
#import "LocalSendReceiver.h"
#import "LocalSendReceivedFileStore.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>

NSString *const LocalSendReceiveRequestNotification = @"LocalSendReceiveRequestNotification";
NSString *const LocalSendReceiveProgressNotification = @"LocalSendReceiveProgressNotification";
NSString *const LocalSendReceivedFilesDidChangeNotification = @"LocalSendReceivedFilesDidChangeNotification";
NSString *const LocalSendReceivePeerDidRegisterNotification = @"LocalSendReceivePeerDidRegisterNotification";

@interface LocalSendIncomingUpload : NSObject {
  @public
    NSString *sessionIdentifier;
    NSString *fileIdentifier;
    NSString *temporaryPath;
    NSString *finalPath;
    NSString *fileName;
    NSString *fileType;
    int fileDescriptor;
    unsigned long long expectedByteCount;
    unsigned long long receivedByteCount;
    CC_SHA256_CTX sha256Context;
}
@end
@implementation LocalSendIncomingUpload
- (id)init {
    if ((self = [super init])) {
        fileDescriptor = -1;
    }
    return self;
}

- (void)dealloc {
    if (fileDescriptor >= 0) {
        close(fileDescriptor);
    }
    [sessionIdentifier release];
    [fileIdentifier release];
    [temporaryPath release];
    [finalPath release];
    [fileName release];
    [fileType release];
    [super dealloc];
}
@end

static NSString *LocalSendCreateReceiveToken(void) {
    unsigned char bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) {
        return nil;
    }
    NSMutableString *token = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) {
        [token appendFormat:@"%02x", bytes[i]];
    }
    return token;
}
static NSDictionary *LocalSendJSONResponse(NSInteger status, id payload) {
    NSData *body = payload != nil ? [LocalSendJSON dataWithJSONObject:payload options:0 error:NULL]
                                  : [NSData data];
    return [NSDictionary
        dictionaryWithObjectsAndKeys:[NSNumber numberWithInteger:status], @"status", body, @"body", nil];
}
static NSDictionary *LocalSendParseReceiveQuery(NSString *target) {
    NSRange separator = [target rangeOfString:@"?"];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if (separator.location == NSNotFound) {
        return result;
    }
    NSString *query = [target substringFromIndex:separator.location + 1];
    for (NSString *part in [query componentsSeparatedByString:@"&"]) {
        NSRange equals = [part rangeOfString:@"="];
        if (equals.location == NSNotFound) {
            return nil;
        }
        NSString *key = [[part substringToIndex:equals.location]
            stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *value = [[part substringFromIndex:equals.location + 1]
            stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        if (key == nil || value == nil || [result objectForKey:key] != nil) {
            return nil;
        }
        [result setObject:value forKey:key];
    }
    return result;
}
static BOOL LocalSendIsValidReceiveString(id value, NSUInteger maximum) {
    return [value isKindOfClass:[NSString class]] && [value length] > 0 && [value length] <= maximum;
}
static BOOL LocalSendReadReceiveFileSize(id value, unsigned long long *byteCount) {
    if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    double numericSize = [value doubleValue];
    if (!isfinite(numericSize) || numericSize < 0 || numericSize > 68719476736.0 ||
        floor(numericSize) != numericSize) {
        return NO;
    }
    *byteCount = [value unsignedLongLongValue];
    return YES;
}
static BOOL LocalSendIsValidReceiveHash(id value) {
    return value == nil || value == [NSNull null] ||
           ([value isKindOfClass:[NSString class]] && [value length] == 64 &&
            [value rangeOfCharacterFromSet:[[NSCharacterSet
                                               characterSetWithCharactersInString:@"0123456789abcdefABCDEF"]
                                               invertedSet]]
                    .location == NSNotFound);
}
static NSString *LocalSendValidatedReceiveFileName(id value) {
    if (!LocalSendIsValidReceiveString(value, 1024) || [value hasPrefix:@"/"] || [value hasPrefix:@"\\"] ||
        [value rangeOfString:@":"].location != NSNotFound ||
        [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) {
        return nil;
    }
    // This version receives individual files, not directory trees.
    if ([value rangeOfString:@"/"].location != NSNotFound ||
        [value rangeOfString:@"\\"].location != NSNotFound || [value isEqual:@"."] || [value isEqual:@".."] ||
        [value hasPrefix:@"."]) {
        return nil;
    }
    if ([[value dataUsingEncoding:NSUTF8StringEncoding] length] > 240) {
        return nil;
    }
    return value;
}

@interface LocalSendReceiver ()
// Locked methods require the receiver condition lock.
- (NSDictionary *)responseForMethodLocked:(NSString *)method
                                     path:(NSString *)path
                                    query:(NSDictionary *)query
                                     body:(NSData *)body
                                     peer:(NSDictionary *)peer
                                   server:(LocalSendReceiveServer *)server;
- (NSDictionary *)registrationResponseForBodyLocked:(NSData *)body peer:(NSDictionary *)peer;
- (NSDictionary *)cancellationResponseForQueryLocked:(NSDictionary *)query peer:(NSDictionary *)peer;
- (NSDictionary *)prepareUploadResponseForBodyLocked:(NSData *)body
                                                peer:(NSDictionary *)peer
                                              server:(LocalSendReceiveServer *)server;
- (NSMutableDictionary *)prepareFilesForUpload:(NSDictionary *)files
                                  displayFiles:(NSMutableArray *)displayFiles
                                totalByteCount:(unsigned long long *)totalByteCount
                                responseStatus:(NSInteger *)status;
- (void)waitForReceiveDecisionLocked:(NSDictionary *)session server:(LocalSendReceiveServer *)server;
- (void)postNotification:(NSString *)notificationName info:(NSDictionary *)info;
- (void)deliverNotification:(NSDictionary *)event;
- (void)progressLocked:(NSString *)status active:(BOOL)active error:(BOOL)error;
- (void)cancelLocked:(NSString *)status error:(BOOL)error;
- (BOOL)peerMatchesLocked:(NSDictionary *)peer;
- (BOOL)hasSpaceLocked:(unsigned long long)byteCount;
- (void)expireLocked;
@end

@implementation LocalSendReceiver
+ (LocalSendReceiver *)sharedReceiver {
    static LocalSendReceiver *receiver = nil;
    @synchronized(self) {
        if (receiver == nil) {
            receiver = [[self alloc] init];
        }
    }
    return receiver;
}

- (id)init {
    if ((self = [super init])) {
        _sessionCondition = [[NSCondition alloc] init];
        _activeUploads = [[NSMutableSet alloc] init];
        _fileStore = [[LocalSendReceivedFileStore alloc] init];
    }
    return self;
}

- (void)setLocalInfo:(NSDictionary *)info {
    [_sessionCondition lock];
    [_localDeviceInfo release];
    _localDeviceInfo = [info copy];
    _isReceivingEnabled = YES;
    [_sessionCondition unlock];
}

- (void)stop {
    [_sessionCondition lock];
    _isReceivingEnabled = NO;
    [self cancelLocked:@"Receiving stopped." error:NO];
    [_sessionCondition unlock];
}

- (void)postNotification:(NSString *)notificationName info:(NSDictionary *)info {
    NSDictionary *event = [NSDictionary
        dictionaryWithObjectsAndKeys:notificationName, @"name",
                                     info != nil ? info : [NSDictionary dictionary], @"info", nil];
    [self performSelectorOnMainThread:@selector(deliverNotification:) withObject:event waitUntilDone:NO];
}

- (void)deliverNotification:(NSDictionary *)event {
    [[NSNotificationCenter defaultCenter] postNotificationName:[event objectForKey:@"name"]
                                                        object:self
                                                      userInfo:[event objectForKey:@"info"]];
}

- (void)progressLocked:(NSString *)status active:(BOOL)active error:(BOOL)error {
    [self postNotification:LocalSendReceiveProgressNotification
                      info:[NSDictionary
                               dictionaryWithObjectsAndKeys:status, @"status",
                                                            [NSNumber numberWithBool:active], @"active",
                                                            [NSNumber numberWithBool:error], @"error", nil]];
}

- (BOOL)peerMatchesLocked:(NSDictionary *)peer {
    return _currentSession != nil && [[peer objectForKey:@"protocol"] isEqual:@"https"] &&
           [[peer objectForKey:@"address"] isEqual:[_currentSession objectForKey:@"address"]] &&
           [[peer objectForKey:@"fingerprint"] isEqual:[_currentSession objectForKey:@"fingerprint"]];
}

- (BOOL)hasSpaceLocked:(unsigned long long)byteCount {
    return [_fileStore hasSpaceForByteCount:byteCount];
}

- (void)expireLocked {
    if (_currentSession != nil && [[_currentSession objectForKey:@"state"] isEqual:@"accepted"] &&
        -[[_currentSession objectForKey:@"lastActivity"] timeIntervalSinceNow] > 120.0) {
        [self cancelLocked:@"Receiving timed out." error:YES];
    }
}

- (void)checkTimeouts {
    [_sessionCondition lock];
    [self expireLocked];
    [_sessionCondition unlock];
}

- (NSDictionary *)pendingRequest {
    [_sessionCondition lock];
    NSDictionary *request = [[_currentSession objectForKey:@"state"] isEqual:@"pending"]
                                ? [_currentSession objectForKey:@"request"]
                                : nil;
    request = [[request retain] autorelease];
    [_sessionCondition unlock];
    return request;
}

- (void)respondToRequest:(NSString *)requestIdentifier accept:(BOOL)accept {
    [_sessionCondition lock];
    if ([[_currentSession objectForKey:@"sessionId"] isEqual:requestIdentifier] &&
        [[_currentSession objectForKey:@"state"] isEqual:@"pending"]) {
        if (accept && [self hasSpaceLocked:[[_currentSession objectForKey:@"total"] unsignedLongLongValue]]) {
            [_currentSession setObject:@"accepted" forKey:@"state"];
            [_currentSession setObject:[NSDate date] forKey:@"lastActivity"];
            [self progressLocked:@"Waiting for the sender…" active:YES error:NO];
        } else {
            [_currentSession setObject:@"declined" forKey:@"state"];
            [self
                progressLocked:accept ? @"Not enough storage to receive these files." : @"Transfer declined."
                        active:NO
                         error:accept];
        }
        [_sessionCondition broadcast];
        [self postNotification:LocalSendReceiveRequestNotification info:nil];
    }
    [_sessionCondition unlock];
}

- (void)cancelLocked:(NSString *)status error:(BOOL)error {
    if (_currentSession == nil) {
        return;
    }
    for (LocalSendIncomingUpload *upload in _activeUploads) {
        if (upload->fileDescriptor >= 0) {
            close(upload->fileDescriptor);
            upload->fileDescriptor = -1;
        }
        [_fileStore removeStagedFileAtPath:upload->temporaryPath];
    }
    [_activeUploads removeAllObjects];
    [_currentSession setObject:@"cancelled" forKey:@"state"];
    [_currentSession release];
    _currentSession = nil;
    [_sessionCondition broadcast];
    [self postNotification:LocalSendReceiveRequestNotification info:nil];
    [self progressLocked:status active:NO error:error];
}

- (void)cancelCurrentTransfer {
    [_sessionCondition lock];
    [self cancelLocked:@"Receiving cancelled." error:NO];
    [_sessionCondition unlock];
}

- (NSArray *)receivedFiles {
    [_sessionCondition lock];
    NSArray *files = [[_fileStore receivedFiles] retain];
    [_sessionCondition unlock];
    return [files autorelease];
}

- (NSUInteger)unseenReceivedFileCount {
    [_sessionCondition lock];
    NSUInteger count = [_fileStore unseenFileCount];
    [_sessionCondition unlock];
    return count;
}

- (BOOL)markReceivedFilesSeen {
    [_sessionCondition lock];
    BOOL saved = [_fileStore markAllFilesSeen];
    [_sessionCondition unlock];
    return saved;
}

- (NSDictionary *)receiveServer:(LocalSendReceiveServer *)server
              responseForMethod:(NSString *)method
                         target:(NSString *)target
                        headers:(NSDictionary *)headers
                           body:(NSData *)body
                           peer:(NSDictionary *)peer {
    NSString *path = [[target componentsSeparatedByString:@"?"] objectAtIndex:0];
    NSDictionary *query = LocalSendParseReceiveQuery(target);
    if (query == nil) {
        return LocalSendJSONResponse(400, nil);
    }
    [_sessionCondition lock];
    NSDictionary *response = [[self responseForMethodLocked:method
                                                       path:path
                                                      query:query
                                                       body:body
                                                       peer:peer
                                                     server:server] retain];
    [_sessionCondition unlock];
    return [response autorelease];
}

- (NSDictionary *)responseForMethodLocked:(NSString *)method
                                     path:(NSString *)path
                                    query:(NSDictionary *)query
                                     body:(NSData *)body
                                     peer:(NSDictionary *)peer
                                   server:(LocalSendReceiveServer *)server {
    if (!_isReceivingEnabled) {
        return LocalSendJSONResponse(503, nil);
    }
    [self expireLocked];
    if ([path isEqual:@"/api/localsend/v2/info"] && [method isEqual:@"GET"]) {
        return LocalSendJSONResponse(200, _localDeviceInfo);
    }
    if ([path isEqual:@"/api/localsend/v2/register"] && [method isEqual:@"POST"]) {
        return [self registrationResponseForBodyLocked:body peer:peer];
    }
    if (![[peer objectForKey:@"protocol"] isEqual:@"https"] ||
        !LocalSendIsValidReceiveString([peer objectForKey:@"fingerprint"], 64)) {
        return LocalSendJSONResponse(426, nil);
    }
    if ([path isEqual:@"/api/localsend/v2/cancel"] && [method isEqual:@"POST"]) {
        return [self cancellationResponseForQueryLocked:query peer:peer];
    }
    if ([path isEqual:@"/api/localsend/v2/prepare-upload"] && [method isEqual:@"POST"]) {
        return [self prepareUploadResponseForBodyLocked:body peer:peer server:server];
    }
    return LocalSendJSONResponse(404, nil);
}

- (NSDictionary *)registrationResponseForBodyLocked:(NSData *)body peer:(NSDictionary *)peer {
    id payload = [LocalSendJSON JSONObjectWithData:body options:0 error:NULL];
    id alias = [payload isKindOfClass:[NSDictionary class]] ? [payload objectForKey:@"alias"] : nil;
    if (!LocalSendIsValidReceiveString(alias, 256)) {
        return LocalSendJSONResponse(400, nil);
    }
    NSMutableDictionary *message = [[payload mutableCopy] autorelease];
    if ([[peer objectForKey:@"protocol"] isEqual:@"https"]) {
        [message setObject:[peer objectForKey:@"fingerprint"] forKey:@"fingerprint"];
    }
    [self postNotification:LocalSendReceivePeerDidRegisterNotification
                      info:[NSDictionary dictionaryWithObjectsAndKeys:message, @"message",
                                                                      [peer objectForKey:@"address"],
                                                                      @"address", nil]];
    return LocalSendJSONResponse(200, _localDeviceInfo);
}

- (NSDictionary *)cancellationResponseForQueryLocked:(NSDictionary *)query peer:(NSDictionary *)peer {
    BOOL pending = [[_currentSession objectForKey:@"state"] isEqual:@"pending"];
    NSString *sessionIdentifier = [query objectForKey:@"sessionId"];
    BOOL authorized = [self peerMatchesLocked:peer] &&
                      ((pending && sessionIdentifier == nil) ||
                       [sessionIdentifier isEqual:[_currentSession objectForKey:@"sessionId"]]);
    if (authorized) {
        [self cancelLocked:@"The sender cancelled the transfer." error:NO];
    }
    return LocalSendJSONResponse(authorized ? 200 : 403, nil);
}

- (NSMutableDictionary *)prepareFilesForUpload:(NSDictionary *)files
                                  displayFiles:(NSMutableArray *)displayFiles
                                totalByteCount:(unsigned long long *)totalByteCount
                                responseStatus:(NSInteger *)status {
    NSMutableDictionary *acceptedFiles = [NSMutableDictionary dictionary];
    unsigned long long combinedByteCount = 0;
    for (NSString *fileIdentifier in [[files allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        id file = [files objectForKey:fileIdentifier];
        if (!LocalSendIsValidReceiveString(fileIdentifier, 256) ||
            ![file isKindOfClass:[NSDictionary class]]) {
            *status = 400;
            return nil;
        }
        NSString *fileName = LocalSendValidatedReceiveFileName([file objectForKey:@"fileName"]);
        NSString *fileType = [file objectForKey:@"fileType"];
        unsigned long long byteCount;
        if (fileName == nil || !LocalSendIsValidReceiveString(fileType, 256) ||
            ![[file objectForKey:@"id"] isEqual:fileIdentifier] ||
            !LocalSendReadReceiveFileSize([file objectForKey:@"size"], &byteCount) ||
            !LocalSendIsValidReceiveHash([file objectForKey:@"sha256"]) ||
            combinedByteCount > 68719476736ULL - byteCount) {
            *status = 400;
            return nil;
        }
        NSString *token = LocalSendCreateReceiveToken();
        if (token == nil) {
            *status = 500;
            return nil;
        }
        NSMutableDictionary *entry = [NSMutableDictionary
            dictionaryWithObjectsAndKeys:fileName, @"fileName", fileType, @"fileType",
                                         [NSNumber numberWithUnsignedLongLong:byteCount], @"size", token,
                                         @"token", @"waiting", @"state", nil];
        id sha256 = [file objectForKey:@"sha256"];
        if ([sha256 isKindOfClass:[NSString class]]) {
            [entry setObject:[sha256 lowercaseString] forKey:@"sha256"];
        }
        [acceptedFiles setObject:entry forKey:fileIdentifier];
        [displayFiles
            addObject:[NSDictionary
                          dictionaryWithObjectsAndKeys:fileName, @"fileName", fileType, @"fileType",
                                                       [NSNumber numberWithUnsignedLongLong:byteCount],
                                                       @"size", nil]];
        combinedByteCount += byteCount;
    }
    *totalByteCount = combinedByteCount;
    return acceptedFiles;
}

- (NSDictionary *)prepareUploadResponseForBodyLocked:(NSData *)body
                                                peer:(NSDictionary *)peer
                                              server:(LocalSendReceiveServer *)server {
    if (_currentSession != nil) {
        return LocalSendJSONResponse(409, nil);
    }
    id payload = [LocalSendJSON JSONObjectWithData:body options:0 error:NULL];
    NSDictionary *info = [payload isKindOfClass:[NSDictionary class]] ? [payload objectForKey:@"info"] : nil;
    NSDictionary *files =
        [payload isKindOfClass:[NSDictionary class]] ? [payload objectForKey:@"files"] : nil;
    NSString *alias = [info isKindOfClass:[NSDictionary class]] ? [info objectForKey:@"alias"] : nil;
    if (!LocalSendIsValidReceiveString(alias, 256) || ![files isKindOfClass:[NSDictionary class]] ||
        [files count] == 0 || [files count] > 100) {
        return LocalSendJSONResponse(400, nil);
    }
    NSMutableArray *displayFiles = [NSMutableArray array];
    unsigned long long totalByteCount = 0;
    NSInteger validationStatus = 400;
    NSMutableDictionary *acceptedFiles = [self prepareFilesForUpload:files
                                                        displayFiles:displayFiles
                                                      totalByteCount:&totalByteCount
                                                      responseStatus:&validationStatus];
    if (acceptedFiles == nil) {
        return LocalSendJSONResponse(validationStatus, nil);
    }
    if (![self hasSpaceLocked:totalByteCount]) {
        return LocalSendJSONResponse(507, nil);
    }
    NSString *sessionIdentifier = LocalSendCreateReceiveToken();
    if (sessionIdentifier == nil) {
        return LocalSendJSONResponse(500, nil);
    }
    NSDictionary *request = [NSDictionary
        dictionaryWithObjectsAndKeys:sessionIdentifier, @"requestId", alias, @"senderAlias", displayFiles,
                                     @"files", [NSNumber numberWithUnsignedLongLong:totalByteCount],
                                     @"totalBytes", nil];
    _currentSession = [[NSMutableDictionary alloc]
        initWithObjectsAndKeys:sessionIdentifier, @"sessionId", acceptedFiles, @"files", request, @"request",
                               [peer objectForKey:@"address"], @"address", [peer objectForKey:@"fingerprint"],
                               @"fingerprint", @"pending", @"state",
                               [NSNumber numberWithUnsignedLongLong:totalByteCount], @"total",
                               [NSNumber numberWithUnsignedLongLong:0], @"received", [NSDate date],
                               @"lastActivity", nil];
    NSMutableDictionary *session = [_currentSession retain];
    [self postNotification:LocalSendReceiveRequestNotification info:nil];
    [self waitForReceiveDecisionLocked:session server:server];
    NSDictionary *response;
    if (_isReceivingEnabled && _currentSession == session &&
        [[session objectForKey:@"state"] isEqual:@"accepted"]) {
        NSMutableDictionary *tokens = [NSMutableDictionary dictionary];
        for (NSString *fileIdentifier in acceptedFiles) {
            [tokens setObject:[[acceptedFiles objectForKey:fileIdentifier] objectForKey:@"token"]
                       forKey:fileIdentifier];
        }
        response = LocalSendJSONResponse(200, [NSDictionary dictionaryWithObjectsAndKeys:sessionIdentifier,
                                                                                         @"sessionId", tokens,
                                                                                         @"files", nil]);
    } else {
        if (_currentSession == session) {
            [self cancelLocked:@"Transfer declined or request expired." error:NO];
        }
        response = LocalSendJSONResponse(403, nil);
    }
    [session release];
    return response;
}

- (void)waitForReceiveDecisionLocked:(NSDictionary *)session server:(LocalSendReceiveServer *)server {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120.0];
    while (_isReceivingEnabled && _currentSession == session &&
           [[session objectForKey:@"state"] isEqual:@"pending"]) {
        if ([deadline timeIntervalSinceNow] <= 0.0) {
            break;
        }
        if (server != nil && ![server isCurrentConnectionOpen]) {
            [self cancelLocked:@"The sender disconnected." error:NO];
            break;
        }
        NSDate *nextCheck = [NSDate dateWithTimeIntervalSinceNow:1.0];
        [_sessionCondition
            waitUntilDate:([deadline compare:nextCheck] == NSOrderedAscending ? deadline : nextCheck)];
    }
}

- (id)receiveServer:(LocalSendReceiveServer *)server
    beginUploadToTarget:(NSString *)target
                headers:(NSDictionary *)headers
                   peer:(NSDictionary *)peer
            errorStatus:(NSInteger *)status {
    NSDictionary *query = LocalSendParseReceiveQuery(target);
    *status = 403;
    if (query == nil) {
        *status = 400;
        return nil;
    }
    [_sessionCondition lock];
    [self expireLocked];
    if (!_isReceivingEnabled || ![self peerMatchesLocked:peer] ||
        ![[_currentSession objectForKey:@"state"] isEqual:@"accepted"] ||
        ![[query objectForKey:@"sessionId"] isEqual:[_currentSession objectForKey:@"sessionId"]]) {
        [_sessionCondition unlock];
        return nil;
    }
    NSString *fileIdentifier = [query objectForKey:@"fileId"];
    NSMutableDictionary *file = [[_currentSession objectForKey:@"files"] objectForKey:fileIdentifier ?: @""];
    if (file == nil || ![[file objectForKey:@"token"] isEqual:[query objectForKey:@"token"]]) {
        [_sessionCondition unlock];
        return nil;
    }
    if (![[file objectForKey:@"state"] isEqual:@"waiting"]) {
        *status = 409;
        [_sessionCondition unlock];
        return nil;
    }
    unsigned long long expectedByteCount = [[file objectForKey:@"size"] unsignedLongLongValue];
    NSString *length = [headers objectForKey:@"content-length"];
    if (length != nil && strtoull([length UTF8String], NULL, 10) != expectedByteCount) {
        *status = 400;
        [_sessionCondition unlock];
        return nil;
    }
    if (![self hasSpaceLocked:expectedByteCount]) {
        *status = 507;
        [_sessionCondition unlock];
        return nil;
    }
    NSString *storageIdentifier = LocalSendCreateReceiveToken();
    if (storageIdentifier == nil) {
        *status = 500;
        [_sessionCondition unlock];
        return nil;
    }
    LocalSendIncomingUpload *upload = [[[LocalSendIncomingUpload alloc] init] autorelease];
    upload->temporaryPath = [[_fileStore stagingPathForIdentifier:storageIdentifier] copy];
    upload->finalPath = [[_fileStore destinationPathForIdentifier:storageIdentifier
                                                         fileName:[file objectForKey:@"fileName"]] copy];
    upload->sessionIdentifier = [[_currentSession objectForKey:@"sessionId"] copy];
    upload->fileIdentifier = [fileIdentifier copy];
    upload->fileName = [[file objectForKey:@"fileName"] copy];
    upload->fileType = [[file objectForKey:@"fileType"] copy];
    upload->expectedByteCount = expectedByteCount;
    upload->fileDescriptor = open([upload->temporaryPath fileSystemRepresentation],
                                  O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0600);
    if (upload->fileDescriptor < 0) {
        *status = 507;
        [_sessionCondition unlock];
        return nil;
    }
    CC_SHA256_Init(&upload->sha256Context);
    [_activeUploads addObject:upload];
    [file setObject:@"uploading" forKey:@"state"];
    [_currentSession setObject:[NSDate date] forKey:@"lastActivity"];
    *status = 200;
    [_sessionCondition unlock];
    return upload;
}

- (BOOL)receiveServer:(LocalSendReceiveServer *)server upload:(id)payload appendData:(NSData *)data {
    LocalSendIncomingUpload *upload = payload;
    [_sessionCondition lock];
    if (![_activeUploads containsObject:upload] || upload->fileDescriptor < 0) {
        [_sessionCondition unlock];
        return NO;
    }
    if ([data length] > upload->expectedByteCount - upload->receivedByteCount) {
        [self cancelLocked:@"Receiving failed: the sender sent more bytes than expected." error:YES];
        [_sessionCondition unlock];
        return NO;
    }
    const unsigned char *bytes = [data bytes];
    NSUInteger offset = 0;
    while (offset < [data length]) {
        ssize_t written = write(upload->fileDescriptor, bytes + offset, [data length] - offset);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            [self cancelLocked:@"Receiving failed: could not write the file. Check free storage." error:YES];
            [_sessionCondition unlock];
            return NO;
        }
        offset += written;
    }
    CC_SHA256_Update(&upload->sha256Context, bytes, (CC_LONG)[data length]);
    upload->receivedByteCount += [data length];
    unsigned long long receivedByteCount =
        [[_currentSession objectForKey:@"received"] unsignedLongLongValue] + [data length];
    [_currentSession setObject:[NSNumber numberWithUnsignedLongLong:receivedByteCount] forKey:@"received"];
    [_currentSession setObject:[NSDate date] forKey:@"lastActivity"];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - _lastProgressUpdateTime >= 0.2) {
        _lastProgressUpdateTime = now;
        unsigned long long totalByteCount = [[_currentSession objectForKey:@"total"] unsignedLongLongValue];
        [self progressLocked:[NSString stringWithFormat:@"Receiving… %u%%",
                                                        totalByteCount == 0
                                                            ? 100
                                                            : (unsigned int)((receivedByteCount * 100ULL) /
                                                                             totalByteCount)]
                      active:YES
                       error:NO];
    }
    [_sessionCondition unlock];
    return YES;
}

- (NSInteger)receiveServer:(LocalSendReceiveServer *)server finishUpload:(id)payload {
    LocalSendIncomingUpload *upload = payload;
    [_sessionCondition lock];
    if (![_activeUploads containsObject:upload] || upload->fileDescriptor < 0) {
        [_sessionCondition unlock];
        return 403;
    }
    if (upload->receivedByteCount != upload->expectedByteCount) {
        [self cancelLocked:@"Receiving failed: incomplete file." error:YES];
        [_sessionCondition unlock];
        return 400;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &upload->sha256Context);
    NSMutableString *sha256 = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) {
        [sha256 appendFormat:@"%02x", digest[i]];
    }
    NSMutableDictionary *file = [[_currentSession objectForKey:@"files"] objectForKey:upload->fileIdentifier];
    NSString *expectedSHA256 = [file objectForKey:@"sha256"];
    if (expectedSHA256 != nil && ![sha256 isEqual:expectedSHA256]) {
        close(upload->fileDescriptor);
        upload->fileDescriptor = -1;
        [_fileStore removeStagedFileAtPath:upload->temporaryPath];
        unsigned long long receivedByteCount =
            [[_currentSession objectForKey:@"received"] unsignedLongLongValue] - upload->receivedByteCount;
        [_currentSession setObject:[NSNumber numberWithUnsignedLongLong:receivedByteCount]
                            forKey:@"received"];
        NSUInteger attempts = [[file objectForKey:@"hashFailures"] unsignedIntegerValue] + 1;
        [file setObject:[NSNumber numberWithUnsignedInteger:attempts] forKey:@"hashFailures"];
        [file setObject:@"waiting" forKey:@"state"];
        [_activeUploads removeObject:upload];
        if (attempts >= 3) {
            [self cancelLocked:@"Receiving failed: file checksum mismatch." error:YES];
        }
        [_sessionCondition unlock];
        return 422;
    }
    int syncResult = fsync(upload->fileDescriptor);
    int closeResult = close(upload->fileDescriptor);
    upload->fileDescriptor = -1;
    NSString *saveError = @"Receiving failed: could not save the file.";
    BOOL saved = syncResult == 0 && closeResult == 0 &&
                 [_fileStore saveStagedFileAtPath:upload->temporaryPath
                                  destinationPath:upload->finalPath
                                         fileName:upload->fileName
                                         fileType:upload->fileType
                                        byteCount:upload->receivedByteCount
                                     errorMessage:&saveError];
    if (!saved) {
        [self cancelLocked:saveError error:YES];
        [_sessionCondition unlock];
        return 507;
    }
    [file setObject:@"done" forKey:@"state"];
    [_activeUploads removeObject:upload];
    [self postNotification:LocalSendReceivedFilesDidChangeNotification info:nil];
    BOOL complete = YES;
    for (NSDictionary *item in [[_currentSession objectForKey:@"files"] allValues]) {
        if (![[item objectForKey:@"state"] isEqual:@"done"]) {
            complete = NO;
        }
    }
    if (complete) {
        NSUInteger count = [[_currentSession objectForKey:@"files"] count];
        [_currentSession release];
        _currentSession = nil;
        [self progressLocked:[NSString stringWithFormat:@"Received %u file%@.", (unsigned int)count,
                                                        count == 1 ? @"" : @"s"]
                      active:NO
                       error:NO];
    }
    [_sessionCondition unlock];
    return 200;
}

- (void)receiveServer:(LocalSendReceiveServer *)server abortUpload:(id)upload {
    [_sessionCondition lock];
    if ([_activeUploads containsObject:upload]) {
        [self cancelLocked:@"Receiving failed: the connection was interrupted." error:YES];
    }
    [_sessionCondition unlock];
}

- (void)dealloc {
    [self stop];
    [_sessionCondition release];
    [_activeUploads release];
    [_localDeviceInfo release];
    [_fileStore release];
    [super dealloc];
}
@end
