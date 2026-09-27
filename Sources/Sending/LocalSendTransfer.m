#import "LocalSendJSON.h"
#import "LocalSendTransfer.h"
#import "LocalSendIdentityStore.h"
#import "LocalSendDiscovery.h"
#import "LocalSendSounds.h"
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

NSString *const LocalSendTransferDidUpdateNotification = @"LocalSendTransferDidUpdateNotification";

static NSString *NewFileIdentifier(void) {
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    NSString *identifier = (NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    return identifier;
}

static NSString *ContentTypeForPhotoName(NSString *fileName) {
    NSString *extension = [[fileName pathExtension] lowercaseString];
    if ([extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"] ||
        [extension isEqualToString:@"jpe"]) {
        return @"image/jpeg";
    }
    if ([extension isEqualToString:@"png"]) {
        return @"image/png";
    }
    if ([extension isEqualToString:@"gif"]) {
        return @"image/gif";
    }
    if ([extension isEqualToString:@"tif"] || [extension isEqualToString:@"tiff"]) {
        return @"image/tiff";
    }
    if ([extension isEqualToString:@"bmp"]) {
        return @"image/bmp";
    }
    return @"application/octet-stream";
}

@interface LocalSendTransfer ()
- (id)initWithDevice:(NSDictionary *)device;
- (BOOL)loadIdentity;
- (BOOL)prepareOutgoingFiles;
- (NSDictionary *)outgoingFileForPhoto:(ALAsset *)asset;
- (NSDictionary *)outgoingFileForClipboard;
- (NSData *)prepareUploadRequestBody;
- (void)beginRequestToPath:(NSString *)path
                      body:(NSData *)body
                  bodyFile:(NSString *)filePath
               contentType:(NSString *)contentType;
- (void)beginHTTPRequestToPath:(NSString *)path
                          body:(NSData *)body
                      bodyFile:(NSString *)filePath
                   contentType:(NSString *)contentType;
- (NSString *)uploadPathForFile:(NSDictionary *)file;
- (void)uploadNextFile;
- (void)preparePhotoFile:(NSDictionary *)file;
- (void)photoFilePrepared:(NSDictionary *)result;
- (void)removeTemporaryPhotoFile;
- (void)sendCancellationRequest;
- (void)finishHTTPConnection:(NSURLConnection *)connection;
- (void)handleResponseData:(NSData *)data statusCode:(NSInteger)statusCode;
- (void)handleAcceptanceData:(NSData *)data statusCode:(NSInteger)statusCode;
- (void)handleUploadStatusCode:(NSInteger)statusCode;
- (void)postUploadProgressWithBytesSent:(unsigned long long)bytesSent
                             totalBytes:(unsigned long long)totalBytes;
- (void)postStatus:(NSString *)message;
- (void)postStatus:(NSString *)message isError:(BOOL)isError isActive:(BOOL)isActive;
- (void)completeWithMessage:(NSString *)message;
- (void)failWithMessage:(NSString *)message;
@end

@implementation LocalSendTransfer

- (id)initWithDevice:(NSDictionary *)device {
    self = [super init];
    if (self) {
        _recipientDevice = [device retain];
        _responseData = [[NSMutableData alloc] init];
    }
    return self;
}

- (id)initWithDevice:(NSDictionary *)device photoAssets:(NSArray *)assets library:(ALAssetsLibrary *)library {
    self = [self initWithDevice:device];
    if (self) {
        _photoAssets = [assets copy];
        // ALAsset references depend on this library.
        _photoLibrary = [library retain];
    }
    return self;
}

- (id)initWithDevice:(NSDictionary *)device clipboardText:(NSString *)text {
    self = [self initWithDevice:device];
    if (self) {
        _clipboardText = [text copy];
        _clipboardData = [[text dataUsingEncoding:NSUTF8StringEncoding] retain];
        _clipboardFileIdentifier = NewFileIdentifier();
    }
    return self;
}

- (void)dealloc {
    [self cancel];
    [_httpConnection release];
    [_httpsClient release];
    [_responseData release];
    [_clipboardFileIdentifier release];
    [_clipboardData release];
    [_clipboardText release];
    [_photoAssets release];
    [_photoLibrary release];
    [_outgoingFiles release];
    [_uploadTokensByFileIdentifier release];
    [_uploadSessionIdentifier release];
    [_recipientDevice release];
    [_identityFingerprint release];
    if (_identity != NULL) {
        CFRelease(_identity);
    }
    [super dealloc];
}

- (void)start {
    if (_cancelled) {
        return;
    }
    if ([_clipboardData length] == 0 && [_photoAssets count] == 0) {
        [self failWithMessage:_clipboardText != nil ? @"Transfer failed: there is no clipboard text to send."
                                                    : @"Transfer failed: there is no photo to send."];
        return;
    }
    if (![self loadIdentity]) {
        return;
    }
    NSString *protocol = [_recipientDevice objectForKey:@"protocol"];
    if (![protocol isEqualToString:@"http"] && ![protocol isEqualToString:@"https"]) {
        [self failWithMessage:@"Transfer failed: the recipient advertised an invalid protocol."];
        return;
    }
    if (![self prepareOutgoingFiles]) {
        return;
    }
    NSData *requestBody = [self prepareUploadRequestBody];
    if (requestBody == nil) {
        return;
    }

    _isUploadingFiles = NO;
    NSUInteger photoCount = [_outgoingFiles count];
    [self
        postStatus:_clipboardText != nil
                       ? @"Requesting permission to send clipboard…"
                       : [NSString stringWithFormat:@"Requesting permission to send %u photo%@…",
                                                    (unsigned int)photoCount, photoCount == 1 ? @"" : @"s"]];
    [self beginRequestToPath:@"/api/localsend/v2/prepare-upload"
                        body:requestBody
                    bodyFile:nil
                 contentType:@"application/json"];
}

- (BOOL)loadIdentity {
    if (_identity != NULL && [_identityFingerprint length] == 64) {
        return YES;
    }
    NSString *fingerprint = nil;
    NSString *errorMessage = nil;
    _identity = [LocalSendIdentityStore copyIdentityWithFingerprint:&fingerprint error:&errorMessage];
    if (_identity == NULL) {
        [self failWithMessage:[NSString stringWithFormat:@"Transfer failed: %@", errorMessage]];
        return NO;
    }
    _identityFingerprint = [fingerprint copy];
    return YES;
}

- (NSDictionary *)outgoingFileForPhoto:(ALAsset *)asset {
    ALAssetRepresentation *representation = [asset defaultRepresentation];
    NSString *fileName = [[representation filename] lastPathComponent];
    NSUInteger byteCount = [representation size];
    if (representation == nil || [fileName length] == 0 || byteCount == 0 || [fileName hasPrefix:@"."] ||
        [fileName rangeOfString:@":"].location != NSNotFound ||
        [[fileName dataUsingEncoding:NSUTF8StringEncoding] length] > 240) {
        [self failWithMessage:@"Transfer failed: a selected photo has invalid name or data."];
        return nil;
    }
    NSString *fileIdentifier = NewFileIdentifier();
    NSDictionary *file = [NSDictionary
        dictionaryWithObjectsAndKeys:fileIdentifier, @"id", fileName, @"fileName",
                                     [NSNumber numberWithUnsignedInteger:byteCount], @"size",
                                     ContentTypeForPhotoName(fileName), @"fileType", asset, @"asset", nil];
    [fileIdentifier release];
    return file;
}

- (NSDictionary *)outgoingFileForClipboard {
    return [NSDictionary
        dictionaryWithObjectsAndKeys:_clipboardFileIdentifier, @"id", @"Clipboard.txt", @"fileName",
                                     [NSNumber numberWithUnsignedInteger:[_clipboardData length]], @"size",
                                     @"text/plain", @"fileType", _clipboardText, @"preview", _clipboardData,
                                     @"data", nil];
}

- (BOOL)prepareOutgoingFiles {
    NSMutableArray *files = [NSMutableArray array];
    if ([_photoAssets count] > 100) {
        [self failWithMessage:@"Transfer failed: select at most 100 photos."];
        return NO;
    }
    for (ALAsset *asset in _photoAssets) {
        NSDictionary *file = [self outgoingFileForPhoto:asset];
        if (file == nil) {
            return NO;
        }
        [files addObject:file];
    }
    if ([files count] == 0) {
        [files addObject:[self outgoingFileForClipboard]];
    }
    [_outgoingFiles release];
    _outgoingFiles = [files copy];
    return YES;
}

- (NSData *)prepareUploadRequestBody {
    NSMutableDictionary *filesByIdentifier = [NSMutableDictionary dictionary];
    for (NSDictionary *file in _outgoingFiles) {
        NSMutableDictionary *metadata = [NSMutableDictionary dictionaryWithDictionary:file];
        [metadata removeObjectForKey:@"asset"];
        [metadata removeObjectForKey:@"data"];
        [filesByIdentifier setObject:metadata forKey:[file objectForKey:@"id"]];
    }
    NSDictionary *deviceInfo = [NSDictionary
        dictionaryWithObjectsAndKeys:[LocalSendDiscovery deviceName], @"alias", @"iPhone", @"deviceModel", @"mobile",
                                     @"deviceType", @"2.2", @"version", _identityFingerprint, @"fingerprint",
                                     [NSNumber numberWithInt:53317], @"port", @"https", @"protocol",
                                     [NSNumber numberWithBool:NO], @"download", nil];
    NSDictionary *request =
        [NSDictionary dictionaryWithObjectsAndKeys:deviceInfo, @"info", filesByIdentifier, @"files", nil];
    NSError *error = nil;
    NSData *body = [LocalSendJSON dataWithJSONObject:request options:0 error:&error];
    if (body == nil) {
        [self failWithMessage:[NSString
                                  stringWithFormat:@"Transfer failed: could not prepare the request (%@).",
                                                   [error localizedDescription]]];
    }
    return body;
}

- (void)beginRequestToPath:(NSString *)path
                      body:(NSData *)body
                  bodyFile:(NSString *)filePath
               contentType:(NSString *)contentType {
    if (_cancelled) {
        return;
    }
    NSString *protocol = [_recipientDevice objectForKey:@"protocol"];
    if ([protocol isEqualToString:@"https"]) {
        [_httpsClient invalidate];
        [_httpsClient release];
        _httpsClient =
            [[LocalSendHTTPSClient alloc] initWithHost:[_recipientDevice objectForKey:@"address"]
                                                  port:[_recipientDevice objectForKey:@"port"]
                                              identity:_identity
                                   expectedFingerprint:[_recipientDevice objectForKey:@"fingerprint"]
                                              delegate:self];
        if (filePath != nil) {
            [_httpsClient postPath:path bodyFile:filePath contentType:contentType];
        } else {
            [_httpsClient postPath:path body:body contentType:contentType];
        }
    } else if ([protocol isEqualToString:@"http"]) {
        [self beginHTTPRequestToPath:path body:body bodyFile:filePath contentType:contentType];
    } else {
        [self failWithMessage:@"Transfer failed: unsupported transport protocol."];
    }
}

- (void)beginHTTPRequestToPath:(NSString *)path
                          body:(NSData *)body
                      bodyFile:(NSString *)filePath
                   contentType:(NSString *)contentType {
    NSString *urlString =
        [NSString stringWithFormat:@"http://%@:%@%@", [_recipientDevice objectForKey:@"address"],
                                   [_recipientDevice objectForKey:@"port"], path];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    if ([path isEqualToString:@"/api/localsend/v2/prepare-upload"]) {
        [request setTimeoutInterval:130.0];
    }
    [request setHTTPMethod:@"POST"];
    [request setValue:contentType forHTTPHeaderField:@"Content-Type"];
    if (filePath != nil) {
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath
                                                                                    error:NULL];
        NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:filePath];
        if (attributes == nil || stream == nil) {
            [self failWithMessage:@"Transfer failed: selected photo is unavailable."];
            return;
        }
        [request setHTTPBodyStream:stream];
        [request setValue:[[attributes objectForKey:NSFileSize] description]
            forHTTPHeaderField:@"Content-Length"];
    } else {
        [request setHTTPBody:body];
    }
    [_httpConnection cancel];
    [_httpConnection release];
    [_responseData setLength:0];
    _responseStatusCode = 0;
    _httpConnection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
}

- (NSURLRequest *)connection:(NSURLConnection *)connection
             willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)response {
    if (response != nil) {
        [self failWithMessage:@"Transfer failed: the recipient redirected the request."];
        return nil;
    }
    return request;
}

- (void)httpsClient:(LocalSendHTTPSClient *)client
    didCompleteWithStatus:(NSInteger)status
                     body:(NSData *)body {
    if (_cancelled || client != _httpsClient) {
        return;
    }
    NSData *responseBody = [body retain];
    [_httpsClient invalidate];
    [_httpsClient release];
    _httpsClient = nil;
    [self handleResponseData:responseBody statusCode:status];
    [responseBody release];
}

- (void)httpsClient:(LocalSendHTTPSClient *)client didFailWithMessage:(NSString *)message {
    if (_cancelled || client != _httpsClient) {
        return;
    }
    [_httpsClient invalidate];
    [_httpsClient release];
    _httpsClient = nil;
    [self failWithMessage:[NSString stringWithFormat:@"Transfer failed: %@", message]];
}

- (void)httpsClient:(LocalSendHTTPSClient *)client
    didSendBodyBytes:(NSUInteger)sent
          totalBytes:(NSUInteger)total {
    if (_cancelled || client != _httpsClient || !_isUploadingFiles) {
        return;
    }
    [self postUploadProgressWithBytesSent:sent totalBytes:total];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if (_cancelled || connection != _httpConnection) {
        return;
    }
    _responseStatusCode = [(NSHTTPURLResponse *)response statusCode];
    [_responseData setLength:0];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (_cancelled || connection != _httpConnection) {
        return;
    }
    [_responseData appendData:data];
}

- (void)connection:(NSURLConnection *)connection
              didSendBodyData:(NSInteger)bytesWritten
            totalBytesWritten:(NSInteger)totalBytesWritten
    totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite {
    if (_cancelled || connection != _httpConnection || !_isUploadingFiles || totalBytesExpectedToWrite <= 0) {
        return;
    }
    [self postUploadProgressWithBytesSent:(unsigned long long)totalBytesWritten
                               totalBytes:(unsigned long long)totalBytesExpectedToWrite];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    if (_cancelled || connection != _httpConnection) {
        return;
    }
    [self finishHTTPConnection:connection];
    [self handleResponseData:_responseData statusCode:_responseStatusCode];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    if (_cancelled || connection != _httpConnection) {
        return;
    }
    [self finishHTTPConnection:connection];
    [self failWithMessage:[NSString stringWithFormat:@"Transfer failed (%@, %ld).",
                                                     [error localizedDescription], (long)[error code]]];
}

- (void)finishHTTPConnection:(NSURLConnection *)connection {
    if (_httpConnection == connection) {
        [_httpConnection release];
        _httpConnection = nil;
    }
}

- (void)handleResponseData:(NSData *)data statusCode:(NSInteger)statusCode {
    if (_isUploadingFiles) {
        [self handleUploadStatusCode:statusCode];
    } else {
        [self handleAcceptanceData:data statusCode:statusCode];
    }
}

- (void)handleAcceptanceData:(NSData *)data statusCode:(NSInteger)statusCode {
    if (statusCode == 204) {
        [self completeWithMessage:_clipboardText != nil ? @"Clipboard sent." : @"Transfer completed."];
        return;
    }
    if (statusCode != 200) {
        [self
            failWithMessage:[NSString stringWithFormat:
                                          @"Transfer failed: the recipient did not accept the %@ (HTTP %ld).",
                                          _clipboardText != nil ? @"clipboard" : @"photo", (long)statusCode]];
        return;
    }
    NSDictionary *response = [LocalSendJSON JSONObjectWithData:data options:0 error:NULL];
    if (![response isKindOfClass:[NSDictionary class]]) {
        [self failWithMessage:@"Transfer failed: invalid response from the recipient."];
        return;
    }
    NSDictionary *acceptedFiles = [response objectForKey:@"files"];
    NSString *sessionIdentifier = [response objectForKey:@"sessionId"];
    if (![acceptedFiles isKindOfClass:[NSDictionary class]] ||
        ![sessionIdentifier isKindOfClass:[NSString class]] || [sessionIdentifier length] == 0) {
        [self failWithMessage:@"Transfer failed: invalid acceptance from the recipient."];
        return;
    }
    for (NSDictionary *file in _outgoingFiles) {
        NSString *token = [acceptedFiles objectForKey:[file objectForKey:@"id"]];
        if (![token isKindOfClass:[NSString class]] || [token length] == 0) {
            [self failWithMessage:@"Transfer failed: the recipient did not accept every photo."];
            return;
        }
    }
    _uploadTokensByFileIdentifier = [acceptedFiles copy];
    _uploadSessionIdentifier = [sessionIdentifier copy];
    _isUploadingFiles = YES;
    _currentFileIndex = 0;
    [self uploadNextFile];
}

- (void)handleUploadStatusCode:(NSInteger)statusCode {
    if (statusCode != 200) {
        [self failWithMessage:[NSString stringWithFormat:@"Transfer failed: %@ %u of %u failed (HTTP %ld).",
                                                         _clipboardText != nil ? @"Clipboard" : @"Photo",
                                                         (unsigned int)(_currentFileIndex + 1),
                                                         (unsigned int)[_outgoingFiles count],
                                                         (long)statusCode]];
        return;
    }
    [self removeTemporaryPhotoFile];
    _currentFileIndex++;
    if (_currentFileIndex < [_outgoingFiles count]) {
        [self uploadNextFile];
        return;
    }
    NSUInteger sentCount = [_outgoingFiles count];
    [self completeWithMessage:_clipboardText != nil
                                  ? @"Clipboard sent."
                                  : [NSString stringWithFormat:@"Sent %u photo%@.", (unsigned int)sentCount,
                                                               sentCount == 1 ? @"" : @"s"]];
}

- (NSString *)uploadPathForFile:(NSDictionary *)file {
    NSString *fileIdentifier = [file objectForKey:@"id"];
    return [NSString stringWithFormat:@"/api/localsend/v2/upload?sessionId=%@&fileId=%@&token=%@",
                                      _uploadSessionIdentifier, fileIdentifier,
                                      [_uploadTokensByFileIdentifier objectForKey:fileIdentifier]];
}

- (void)uploadNextFile {
    if (_cancelled || _currentFileIndex >= [_outgoingFiles count]) {
        return;
    }
    NSDictionary *file = [_outgoingFiles objectAtIndex:_currentFileIndex];
    if ([file objectForKey:@"asset"] != nil) {
        [self postStatus:[NSString stringWithFormat:@"Preparing photo %u of %u…",
                                                    (unsigned int)(_currentFileIndex + 1),
                                                    (unsigned int)[_outgoingFiles count]]];
        [NSThread detachNewThreadSelector:@selector(preparePhotoFile:) toTarget:self withObject:file];
        return;
    }
    [self beginRequestToPath:[self uploadPathForFile:file]
                        body:[file objectForKey:@"data"]
                    bodyFile:nil
                 contentType:@"application/octet-stream"];
}

- (void)preparePhotoFile:(NSDictionary *)file {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    ALAssetRepresentation *representation = [[file objectForKey:@"asset"] defaultRepresentation];
    unsigned long long expectedByteCount = [[file objectForKey:@"size"] unsignedLongLongValue];
    NSString *uniqueIdentifier = NewFileIdentifier();
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"LocalSend-%@.part", uniqueIdentifier]];
    [uniqueIdentifier release];
    int fileDescriptor = open([path fileSystemRepresentation], O_CREAT | O_EXCL | O_WRONLY, 0600);
    BOOL copySucceeded = representation != nil && expectedByteCount > 0 &&
                         expectedByteCount == [representation size] && fileDescriptor >= 0;
    unsigned char buffer[32768];
    unsigned long long bytesCopied = 0;
    while (copySucceeded && bytesCopied < expectedByteCount) {
        if (_cancelled) {
            copySucceeded = NO;
            break;
        }
        NSUInteger bytesRequested =
            (NSUInteger)MIN((unsigned long long)sizeof(buffer), expectedByteCount - bytesCopied);
        NSError *error = nil;
        NSUInteger bytesRead = [representation getBytes:buffer
                                             fromOffset:(long long)bytesCopied
                                                 length:bytesRequested
                                                  error:&error];
        if (bytesRead == 0 || error != nil) {
            copySucceeded = NO;
            break;
        }
        NSUInteger bytesWritten = 0;
        while (bytesWritten < bytesRead) {
            ssize_t result = write(fileDescriptor, buffer + bytesWritten, bytesRead - bytesWritten);
            if (result < 0 && errno == EINTR) {
                continue;
            }
            if (result <= 0) {
                copySucceeded = NO;
                break;
            }
            bytesWritten += (NSUInteger)result;
        }
        if (copySucceeded) {
            bytesCopied += bytesRead;
        }
    }
    if (fileDescriptor >= 0 && close(fileDescriptor) != 0) {
        copySucceeded = NO;
    }
    copySucceeded = copySucceeded && bytesCopied == expectedByteCount;
    if (!copySucceeded) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }
    NSDictionary *result =
        [NSDictionary dictionaryWithObjectsAndKeys:file, @"file", copySucceeded ? path : @"", @"path", nil];
    [self performSelectorOnMainThread:@selector(photoFilePrepared:) withObject:result waitUntilDone:NO];
    [pool drain];
}

- (void)photoFilePrepared:(NSDictionary *)result {
    NSString *path = [result objectForKey:@"path"];
    NSDictionary *file = [result objectForKey:@"file"];
    if (_cancelled || !_isUploadingFiles || _currentFileIndex >= [_outgoingFiles count] ||
        [_outgoingFiles objectAtIndex:_currentFileIndex] != file) {
        if ([path length] > 0) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        }
        return;
    }
    if ([path length] == 0) {
        [self
            failWithMessage:@"Transfer failed: could not read a selected photo or save its temporary copy."];
        return;
    }
    _temporaryPhotoFilePath = [path copy];
    [self beginRequestToPath:[self uploadPathForFile:file]
                        body:nil
                    bodyFile:path
                 contentType:@"application/octet-stream"];
}

- (void)removeTemporaryPhotoFile {
    if (_temporaryPhotoFilePath == nil) {
        return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:_temporaryPhotoFilePath error:NULL];
    [_temporaryPhotoFilePath release];
    _temporaryPhotoFilePath = nil;
}

- (void)postUploadProgressWithBytesSent:(unsigned long long)bytesSent
                             totalBytes:(unsigned long long)totalBytes {
    if (totalBytes == 0) {
        return;
    }
    NSUInteger percentage = (NSUInteger)((bytesSent * 100ULL) / totalBytes);
    [self postStatus:_clipboardText != nil
                         ? [NSString stringWithFormat:@"Sending clipboard… %u%%", (unsigned int)percentage]
                         : [NSString stringWithFormat:@"Sending photo %u of %u… %u%%",
                                                      (unsigned int)(_currentFileIndex + 1),
                                                      (unsigned int)[_outgoingFiles count],
                                                      (unsigned int)percentage]];
}

- (void)postStatus:(NSString *)message {
    [self postStatus:message isError:NO isActive:YES];
}

- (void)postStatus:(NSString *)message isError:(BOOL)isError isActive:(BOOL)isActive {
    NSDictionary *details = [NSDictionary
        dictionaryWithObjectsAndKeys:message, @"status", [NSNumber numberWithBool:isError], @"isError",
                                     [NSNumber numberWithBool:isActive], @"isActive", nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:LocalSendTransferDidUpdateNotification
                                                        object:self
                                                      userInfo:details];
}

- (void)completeWithMessage:(NSString *)message {
    [_uploadSessionIdentifier release];
    _uploadSessionIdentifier = nil;
    _isUploadingFiles = NO;
    [self postStatus:message isError:NO isActive:NO];
    [LocalSendSounds playOutgoingTransferComplete];
    [_photoAssets release];
    _photoAssets = nil;
    [_photoLibrary release];
    _photoLibrary = nil;
    [_outgoingFiles release];
    _outgoingFiles = nil;
    [_uploadTokensByFileIdentifier release];
    _uploadTokensByFileIdentifier = nil;
    [_clipboardData release];
    _clipboardData = nil;
}

- (void)failWithMessage:(NSString *)message {
    if (_cancelled) {
        return;
    }
    [self cancel];
    [self postStatus:message isError:YES isActive:NO];
}

- (void)sendCancellationRequest {
    if (_uploadSessionIdentifier == nil) {
        return;
    }
    NSString *path =
        [NSString stringWithFormat:@"/api/localsend/v2/cancel?sessionId=%@", _uploadSessionIdentifier];
    [_uploadSessionIdentifier release];
    _uploadSessionIdentifier = nil;
    NSString *protocol = [_recipientDevice objectForKey:@"protocol"];
    if ([protocol isEqualToString:@"https"]) {
        LocalSendHTTPSClient *client =
            [[LocalSendHTTPSClient alloc] initWithHost:[_recipientDevice objectForKey:@"address"]
                                                  port:[_recipientDevice objectForKey:@"port"]
                                              identity:_identity
                                   expectedFingerprint:[_recipientDevice objectForKey:@"fingerprint"]
                                              delegate:nil];
        [client postPath:path body:[NSData data] contentType:@"application/json"];
        [client release];
    } else if ([protocol isEqualToString:@"http"]) {
        NSString *urlString =
            [NSString stringWithFormat:@"http://%@:%@%@", [_recipientDevice objectForKey:@"address"],
                                       [_recipientDevice objectForKey:@"port"], path];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        [request setHTTPMethod:@"POST"];
        [request setHTTPBody:[NSData data]];
        [NSURLConnection connectionWithRequest:request delegate:nil];
    }
}

- (void)cancel {
    if (_cancelled) {
        return;
    }
    _cancelled = YES;
    [_httpConnection cancel];
    [_httpsClient invalidate];
    [self sendCancellationRequest];
    [self removeTemporaryPhotoFile];
}

@end
