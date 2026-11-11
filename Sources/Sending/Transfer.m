#import "Transfer+Private.h"
#import "IdentityStore.h"
#import "Sounds.h"

NSString *const TransferDidUpdateNotification = @"LocalSendTransferDidUpdateNotification";

@implementation Transfer

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

- (id)initWithDevice:(NSDictionary *)device contactsFileAtPath:(NSString *)path fileName:(NSString *)name {
    self = [self initWithDevice:device];
    if (self) {
        _contactsFilePath = [path copy];
        _contactsFileName = [name copy];
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
    [_contactsFileName release];
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
    if (_contactsFileName == nil && [_clipboardData length] == 0 && [_photoAssets count] == 0) {
        [self failWithMessage:_clipboardText != nil ? @"Transfer failed: there is no clipboard text to send."
                                                    : @"Transfer failed: there is no photo or video to send."];
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
    NSUInteger videoCount = 0;
    for (NSDictionary *file in _outgoingFiles) {
        if ([[file objectForKey:@"fileType"] hasPrefix:@"video/"]) videoCount++;
    }
    [self
        postStatus:_contactsFileName != nil ? @"Requesting permission to send contacts…" : _clipboardText != nil
                       ? @"Requesting permission to send clipboard…"
                       : [NSString stringWithFormat:@"Requesting permission to send %u %@…",
                                                    (unsigned int)photoCount,
                                                    videoCount == 0 ? (photoCount == 1 ? @"photo" : @"photos") :
                                                    videoCount == photoCount ? (photoCount == 1 ? @"video" : @"videos") : @"items"]];
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
    _identity = [IdentityStore copyIdentityWithFingerprint:&fingerprint error:&errorMessage];
    if (_identity == NULL) {
        [self failWithMessage:[NSString stringWithFormat:@"Transfer failed: %@", errorMessage]];
        return NO;
    }
    _identityFingerprint = [fingerprint copy];
    return YES;
}

- (void)removeContactsFile {
    if (_contactsFilePath != nil) [[NSFileManager defaultManager] removeItemAtPath:_contactsFilePath error:NULL];
    [_contactsFilePath release];
    _contactsFilePath = nil;
}

- (void)postUploadProgressWithBytesSent:(unsigned long long)bytesSent
                             totalBytes:(unsigned long long)totalBytes {
    if (totalBytes == 0) {
        return;
    }
    NSUInteger percentage = (NSUInteger)((bytesSent * 100ULL) / totalBytes);
    [self postStatus:_contactsFileName != nil
                         ? [NSString stringWithFormat:@"Sending contacts… %u%%", (unsigned int)percentage]
                         : _clipboardText != nil
                         ? [NSString stringWithFormat:@"Sending clipboard… %u%%", (unsigned int)percentage]
                         : [NSString stringWithFormat:@"Sending %@ %u of %u… %u%%",
                                                      [[[_outgoingFiles objectAtIndex:_currentFileIndex] objectForKey:@"fileType"] hasPrefix:@"video/"] ? @"video" : @"photo",
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
    [[NSNotificationCenter defaultCenter] postNotificationName:TransferDidUpdateNotification
                                                        object:self
                                                      userInfo:details];
}

- (void)completeWithMessage:(NSString *)message {
    [self removeContactsFile];
    [_uploadSessionIdentifier release];
    _uploadSessionIdentifier = nil;
    _isUploadingFiles = NO;
    [self postStatus:message isError:NO isActive:NO];
    [Sounds playOutgoingTransferComplete];
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
        HTTPSClient *client =
            [[HTTPSClient alloc] initWithHost:[_recipientDevice objectForKey:@"address"]
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
    [self removeContactsFile];
}
@end
