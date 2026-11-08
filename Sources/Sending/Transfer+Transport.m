#import "Transfer+Private.h"

@implementation Transfer (Transport)

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
            [[HTTPSClient alloc] initWithHost:[_recipientDevice objectForKey:@"address"]
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
            [self failWithMessage:@"Transfer failed: selected photo or video is unavailable."];
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

- (void)httpsClient:(HTTPSClient *)client
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

- (void)httpsClient:(HTTPSClient *)client didFailWithMessage:(NSString *)message {
    if (_cancelled || client != _httpsClient) {
        return;
    }
    [_httpsClient invalidate];
    [_httpsClient release];
    _httpsClient = nil;
    [self failWithMessage:[NSString stringWithFormat:@"Transfer failed: %@", message]];
}

- (void)httpsClient:(HTTPSClient *)client
    didSendBodyBytes:(unsigned long long)sent
          totalBytes:(unsigned long long)total {
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
@end
