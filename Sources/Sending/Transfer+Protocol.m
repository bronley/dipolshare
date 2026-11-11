#import "Transfer+Private.h"
#import "JSON.h"
#import "Discovery.h"

@implementation Transfer (Protocol)

- (NSData *)prepareUploadRequestBody {
    NSMutableDictionary *filesByIdentifier = [NSMutableDictionary dictionary];
    for (NSDictionary *file in _outgoingFiles) {
        NSMutableDictionary *metadata = [NSMutableDictionary dictionaryWithDictionary:file];
        [metadata removeObjectForKey:@"asset"];
        [metadata removeObjectForKey:@"data"];
        [filesByIdentifier setObject:metadata forKey:[file objectForKey:@"id"]];
    }
    NSDictionary *deviceInfo = [NSDictionary
        dictionaryWithObjectsAndKeys:[Discovery deviceName], @"alias", @"iPhone", @"deviceModel", @"mobile",
                                     @"deviceType", @"2.2", @"version", _identityFingerprint, @"fingerprint",
                                     [NSNumber numberWithInt:53317], @"port", @"https", @"protocol",
                                     [NSNumber numberWithBool:NO], @"download", nil];
    NSDictionary *request =
        [NSDictionary dictionaryWithObjectsAndKeys:deviceInfo, @"info", filesByIdentifier, @"files", nil];
    NSError *error = nil;
    NSData *body = [JSON dataWithJSONObject:request options:0 error:&error];
    if (body == nil) {
        [self failWithMessage:[NSString
                                  stringWithFormat:@"Transfer failed: could not prepare the request (%@).",
                                                   [error localizedDescription]]];
    }
    return body;
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
        if (_contactsFileName != nil) {
            [self failWithMessage:@"Transfer failed: the recipient did not accept the contact backup file."];
            return;
        }
        [self completeWithMessage:_clipboardText != nil ? @"Clipboard sent." : @"Transfer completed."];
        return;
    }
    if (statusCode != 200) {
        [self
            failWithMessage:[NSString stringWithFormat:
                                          @"Transfer failed: the recipient did not accept the %@ (HTTP %ld).",
                                          _contactsFileName != nil ? @"contact backup" :
                                          _clipboardText != nil ? @"clipboard" : @"media", (long)statusCode]];
        return;
    }
    NSDictionary *response = [JSON JSONObjectWithData:data options:0 error:NULL];
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
            [self failWithMessage:@"Transfer failed: the recipient did not accept every file."];
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
                                                         _clipboardText != nil ? @"Clipboard" : @"File",
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
    NSUInteger videoCount = 0;
    for (NSDictionary *file in _outgoingFiles) {
        if ([[file objectForKey:@"fileType"] hasPrefix:@"video/"]) videoCount++;
    }
    [self completeWithMessage:_contactsFileName != nil ? @"Contacts sent." : _clipboardText != nil
                                  ? @"Clipboard sent."
                                  : [NSString stringWithFormat:@"Sent %u %@.", (unsigned int)sentCount,
                                                               videoCount == 0 ? (sentCount == 1 ? @"photo" : @"photos") :
                                                               videoCount == sentCount ? (sentCount == 1 ? @"video" : @"videos") : @"items"]];
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
    if (_contactsFileName != nil) {
        [self postStatus:@"Sending contacts… 0%"];
        [self beginRequestToPath:[self uploadPathForFile:file] body:nil bodyFile:_contactsFilePath
                     contentType:@"application/octet-stream"];
        return;
    }
    if ([file objectForKey:@"asset"] != nil) {
        [self postStatus:[NSString stringWithFormat:@"Preparing %@ %u of %u…",
                                                    [[file objectForKey:@"fileType"] hasPrefix:@"video/"] ? @"video" : @"photo",
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
@end
