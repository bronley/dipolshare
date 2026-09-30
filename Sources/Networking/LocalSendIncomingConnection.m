#import "LocalSendJSON.h"
#import "LocalSendIncomingConnection.h"
#import <errno.h>
#import <limits.h>
#import <sys/select.h>
#import <sys/socket.h>

static const NSUInteger LocalSendMaximumRequestHeaderLength = 16384;
static const NSUInteger LocalSendMaximumJSONBodyLength = 1024 * 1024;
static const NSUInteger LocalSendReceiveBufferSize = 64 * 1024;
static const NSTimeInterval LocalSendReceiveIdleTimeout = 30.0;

static LocalSendTLSOperationResult LocalSendReadPlainSocket(LocalSendIncomingSocket *socket, void *bytes,
                                                            size_t *length) {
    size_t requested = *length;
    ssize_t count = recv(socket->socketDescriptor, bytes, requested, 0);
    if (count > 0) {
        *length = (size_t)count;
        socket->wantsRead = YES;
        return (size_t)count == requested ? LocalSendTLSOperationCompleted : LocalSendTLSOperationWouldBlock;
    }
    *length = 0;
    if (count == 0) {
        return LocalSendTLSConnectionClosed;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        socket->wantsRead = YES;
        return LocalSendTLSOperationWouldBlock;
    }
    return LocalSendTLSOperationFailed;
}

static LocalSendTLSOperationResult LocalSendWritePlainSocket(LocalSendIncomingSocket *socket,
                                                             const void *bytes, size_t *length) {
    size_t requested = *length;
    ssize_t count = send(socket->socketDescriptor, bytes, requested, 0);
    if (count > 0) {
        *length = (size_t)count;
        socket->wantsRead = NO;
        return (size_t)count == requested ? LocalSendTLSOperationCompleted : LocalSendTLSOperationWouldBlock;
    }
    *length = 0;
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
        socket->wantsRead = NO;
        return LocalSendTLSOperationWouldBlock;
    }
    return LocalSendTLSOperationFailed;
}

static BOOL LocalSendIsValidHTTPToken(NSString *string) {
    if ([string length] == 0) {
        return NO;
    }
    NSUInteger index;
    for (index = 0; index < [string length]; index++) {
        unichar character = [string characterAtIndex:index];
        if ((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9') ||
            (character > 0 && character < 128 && strchr("!#$%&'*+-.^_`|~", (int)character) != NULL)) {
            continue;
        }
        return NO;
    }
    return YES;
}

static BOOL LocalSendIsValidHTTPHeaderValue(NSString *string) {
    NSUInteger index;
    for (index = 0; index < [string length]; index++) {
        unichar character = [string characterAtIndex:index];
        if ((character < 32 && character != '\t') || character == 127) {
            return NO;
        }
    }
    return YES;
}

static BOOL LocalSendParseContentLength(NSString *string, unsigned long long *result) {
    if ([string length] == 0) {
        return NO;
    }
    unsigned long long value = 0;
    NSUInteger index;
    for (index = 0; index < [string length]; index++) {
        unichar character = [string characterAtIndex:index];
        if (character < '0' || character > '9' ||
            value > ((unsigned long long)LLONG_MAX - (character - '0')) / 10) {
            return NO;
        }
        value = value * 10 + character - '0';
    }
    *result = value;
    return YES;
}

static BOOL LocalSendParseRequestChunkSize(NSString *line, unsigned long long *result) {
    NSRange semicolon = [line rangeOfString:@";"];
    NSString *size = semicolon.location == NSNotFound ? line : [line substringToIndex:semicolon.location];
    if ([size length] == 0) {
        return NO;
    }
    unsigned long long value = 0;
    NSUInteger index;
    for (index = 0; index < [size length]; index++) {
        unichar character = [size characterAtIndex:index];
        unsigned int digit;
        if (character >= '0' && character <= '9') {
            digit = character - '0';
        } else if (character >= 'a' && character <= 'f') {
            digit = character - 'a' + 10;
        } else if (character >= 'A' && character <= 'F') {
            digit = character - 'A' + 10;
        } else {
            return NO;
        }
        if (value > ((unsigned long long)LLONG_MAX - digit) / 16) {
            return NO;
        }
        value = value * 16 + digit;
    }
    // Extensions are not interpreted; reject non-visible bytes and empty extensions.
    if (semicolon.location != NSNotFound) {
        if (NSMaxRange(semicolon) == [line length]) {
            return NO;
        }
        for (index = NSMaxRange(semicolon); index < [line length]; index++) {
            unichar character = [line characterAtIndex:index];
            if (character < 32 || character > 126) {
                return NO;
            }
        }
    }
    *result = value;
    return YES;
}

static NSString *LocalSendHTTPReasonPhrase(NSInteger status) {
    switch (status) {
        case 200:
            return @"OK";
        case 204:
            return @"No Content";
        case 400:
            return @"Bad Request";
        case 401:
            return @"Unauthorized";
        case 403:
            return @"Forbidden";
        case 404:
            return @"Not Found";
        case 405:
            return @"Method Not Allowed";
        case 408:
            return @"Request Timeout";
        case 409:
            return @"Conflict";
        case 411:
            return @"Length Required";
        case 413:
            return @"Payload Too Large";
        case 415:
            return @"Unsupported Media Type";
        case 417:
            return @"Expectation Failed";
        case 422:
            return @"Unprocessable Entity";
        case 426:
            return @"Upgrade Required";
        case 429:
            return @"Too Many Requests";
        case 431:
            return @"Request Header Fields Too Large";
        case 500:
            return @"Internal Server Error";
        case 503:
            return @"Service Unavailable";
        case 507:
            return @"Insufficient Storage";
        default:
            return @"Request Failed";
    }
}

static NSDictionary *LocalSendReadHTTPRequest(LocalSendIncomingConnection *connection) {
    connection->errorStatus = 400;
    NSString *line = [connection readLineUpToLength:LocalSendMaximumRequestHeaderLength];
    if (line == nil) {
        return nil;
    }
    NSUInteger total = [line length] + 2;
    NSArray *parts = [line componentsSeparatedByString:@" "];
    if ([parts count] != 3) {
        return nil;
    }
    NSString *method = [parts objectAtIndex:0], *target = [parts objectAtIndex:1],
             *version = [parts objectAtIndex:2];
    if (!LocalSendIsValidHTTPToken(method) || ![target hasPrefix:@"/"] || [target length] > 8192 ||
        (![version isEqualToString:@"HTTP/1.1"] && ![version isEqualToString:@"HTTP/1.0"])) {
        return nil;
    }
    NSUInteger index;
    for (index = 0; index < [target length]; index++) {
        unichar character = [target characterAtIndex:index];
        if (character <= 32 || character >= 127 || character == '#') {
            return nil;
        }
    }
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    while (YES) {
        if (total >= LocalSendMaximumRequestHeaderLength) {
            connection->errorStatus = 431;
            return nil;
        }
        line = [connection readLineUpToLength:LocalSendMaximumRequestHeaderLength - total];
        if (line == nil) {
            return nil;
        }
        total += [line length] + 2;
        if (total > LocalSendMaximumRequestHeaderLength) {
            connection->errorStatus = 431;
            return nil;
        }
        if ([line length] == 0) {
            break;
        }
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            return nil;
        }
        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
        NSString *rawValue = [line substringFromIndex:NSMaxRange(colon)];
        if (!LocalSendIsValidHTTPToken(name) || !LocalSendIsValidHTTPHeaderValue(rawValue) ||
            [headers objectForKey:name] != nil) {
            return nil;
        }
        NSString *value = [rawValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [headers setObject:value forKey:name];
    }
    if ([version isEqualToString:@"HTTP/1.1"] && [[headers objectForKey:@"host"] length] == 0) {
        return nil;
    }
    NSString *lengthHeader = [headers objectForKey:@"content-length"];
    NSString *encoding = [headers objectForKey:@"transfer-encoding"];
    unsigned long long length = 0;
    if (lengthHeader != nil && !LocalSendParseContentLength(lengthHeader, &length)) {
        return nil;
    }
    if (encoding != nil &&
        (lengthHeader != nil || ![[encoding lowercaseString] isEqualToString:@"chunked"])) {
        return nil;
    }
    NSString *expect = [headers objectForKey:@"expect"];
    if (expect != nil && ![[expect lowercaseString] isEqualToString:@"100-continue"]) {
        connection->errorStatus = 417;
        return nil;
    }
    return [NSDictionary
        dictionaryWithObjectsAndKeys:method, @"method", target, @"target", headers, @"headers",
                                     [NSNumber numberWithUnsignedLongLong:length], @"length",
                                     [NSNumber numberWithBool:encoding != nil], @"chunked", nil];
}

static BOOL LocalSendAppendRequestBodyData(LocalSendIncomingConnection *connection, NSData *data,
                                           NSMutableData *body, id<LocalSendReceiveServerDelegate> delegate,
                                           id upload) {
    if ([connection->server isInvalidated]) {
        return NO;
    }
    if (upload != nil) {
        if (![delegate receiveServer:connection->server upload:upload appendData:data]) {
            connection->errorStatus = 422;
            return NO;
        }
    } else {
        [body appendData:data];
    }
    return YES;
}

static BOOL LocalSendReadHTTPRequestBody(LocalSendIncomingConnection *connection, NSDictionary *request,
                                         NSMutableData *body, id<LocalSendReceiveServerDelegate> delegate,
                                         id upload) {
    unsigned long long limit = upload != nil ? (unsigned long long)LLONG_MAX : LocalSendMaximumJSONBodyLength;
    unsigned long long remaining = [[request objectForKey:@"length"] unsignedLongLongValue], received = 0;
    BOOL chunked = [[request objectForKey:@"chunked"] boolValue];
    if (!chunked && remaining > limit) {
        connection->errorStatus = 413;
        return NO;
    }
    while (YES) {
        NSAutoreleasePool *framingPool = [[NSAutoreleasePool alloc] init];
        @try {
            if (chunked) {
                NSString *line = [connection readLineUpToLength:4096];
                if (line == nil || !LocalSendParseRequestChunkSize(line, &remaining)) {
                    return NO;
                }
                if (remaining > limit - received) {
                    connection->errorStatus = 413;
                    return NO;
                }
                if (remaining == 0) {
                    NSUInteger trailerBytes = 0;
                    NSMutableSet *trailerNames = [NSMutableSet set];
                    while (YES) {
                        line = [connection
                            readLineUpToLength:LocalSendMaximumRequestHeaderLength - trailerBytes];
                        if (line == nil) {
                            return NO;
                        }
                        trailerBytes += [line length] + 2;
                        if (trailerBytes > LocalSendMaximumRequestHeaderLength) {
                            return NO;
                        }
                        if ([line length] == 0) {
                            break;
                        }
                        NSRange colon = [line rangeOfString:@":"];
                        if (colon.location == NSNotFound) {
                            return NO;
                        }
                        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
                        if (!LocalSendIsValidHTTPToken(name) ||
                            !LocalSendIsValidHTTPHeaderValue([line substringFromIndex:NSMaxRange(colon)]) ||
                            [trailerNames containsObject:name] || [name isEqualToString:@"content-length"] ||
                            [name isEqualToString:@"transfer-encoding"] || [name isEqualToString:@"host"] ||
                            [name isEqualToString:@"authorization"] || [name isEqualToString:@"trailer"]) {
                            return NO;
                        }
                        [trailerNames addObject:name];
                    }
                    break;
                }
            }
            while (remaining > 0) {
                NSAutoreleasePool *piecePool = [[NSAutoreleasePool alloc] init];
                NSData *piece = [connection
                    readDataUpToLength:(NSUInteger)MIN(remaining,
                                                       (unsigned long long)LocalSendReceiveBufferSize)];
                NSUInteger count = [piece length];
                BOOL okay =
                    count > 0 && LocalSendAppendRequestBodyData(connection, piece, body, delegate, upload);
                [piecePool drain];
                if (!okay) {
                    return NO;
                }
                remaining -= count;
                received += count;
            }
            if (!chunked) {
                break;
            }
            // The CRLF following the bytes is required, including when reads split it.
            NSString *terminator = [connection readLineUpToLength:0];
            if (terminator == nil || [terminator length] != 0) {
                return NO;
            }
        } @finally {
            [framingPool drain];
        }
    }
    // One request per connection; never interpret a second buffered request.
    return [connection->pendingData length] == 0;
}

@implementation LocalSendIncomingConnection
- (id)init {
    self = [super init];
    if (self) {
        socket.socketDescriptor = -1;
        socket.wantsRead = YES;
        pendingData = [[NSMutableData alloc] init];
        errorStatus = 400;
    }
    return self;
}
- (void)dealloc {
    [tls release];
    [activity release];
    [address release];
    [peerFingerprint release];
    [pendingData release];
    [super dealloc];
}
- (BOOL)waitUntil:(NSTimeInterval)deadline {
    while (![server isInvalidated]) {
        NSTimeInterval remaining = deadline - [NSDate timeIntervalSinceReferenceDate];
        if (remaining <= 0) {
            errorStatus = 408;
            return NO;
        }
        fd_set reads, writes;
        FD_ZERO(&reads);
        FD_ZERO(&writes);
        if (socket.wantsRead) {
            FD_SET(socket.socketDescriptor, &reads);
        } else {
            FD_SET(socket.socketDescriptor, &writes);
        }
        struct timeval timeout;
        // Wake periodically so cancellation is checked even without a socket event.
        remaining = MIN(remaining, 1.0);
        timeout.tv_sec = (int)remaining;
        timeout.tv_usec = (int)((remaining - timeout.tv_sec) * 1000000.0);
        int result = select(socket.socketDescriptor + 1, &reads, &writes, NULL, &timeout);
        if (result > 0) {
            return YES;
        }
        if (result < 0 && errno != EINTR) {
            return NO;
        }
    }
    return NO;
}
- (NSData *)readDataUpToLength:(NSUInteger)limit {
    limit = MIN(limit, LocalSendReceiveBufferSize);
    if ([pendingData length] != 0) {
        NSUInteger count = MIN(limit, [pendingData length]);
        NSData *result = [NSData dataWithBytes:[pendingData bytes] length:count];
        [pendingData replaceBytesInRange:NSMakeRange(0, count) withBytes:NULL length:0];
        return result;
    }
    unsigned char bytes[64 * 1024];
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + LocalSendReceiveIdleTimeout;
    while (![server isInvalidated]) {
        size_t count = 0;
        LocalSendTLSOperationResult status;
        if (tls != nil) {
            status = [tls read:bytes length:limit processed:&count];
            socket.wantsRead = [tls wantsRead];
        } else {
            count = limit;
            status = LocalSendReadPlainSocket(&socket, bytes, &count);
        }
        if (count > 0) {
            return [NSData dataWithBytes:bytes length:count];
        }
        if (status != LocalSendTLSOperationCompleted && status != LocalSendTLSOperationWouldBlock) {
            return nil;
        }
        if (![self waitUntil:deadline]) {
            return nil;
        }
    }
    return nil;
}
- (NSString *)readLineUpToLength:(NSUInteger)limit {
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + LocalSendReceiveIdleTimeout;
    while (![server isInvalidated]) {
        const unsigned char *bytes = [pendingData bytes];
        NSUInteger length = [pendingData length], index;
        for (index = 0; index < length; index++) {
            if (bytes[index] == '\n') {
                if (index == 0 || bytes[index - 1] != '\r' || index - 1 > limit) {
                    return nil;
                }
                NSString *line = [[[NSString alloc] initWithBytes:bytes
                                                           length:index - 1
                                                         encoding:NSISOLatin1StringEncoding] autorelease];
                [pendingData replaceBytesInRange:NSMakeRange(0, index + 1) withBytes:NULL length:0];
                return line;
            }
            if (bytes[index] == '\r' && index + 1 < length && bytes[index + 1] != '\n') {
                return nil;
            }
        }
        if (length > limit + 1) {
            return nil;
        }
        unsigned char more[8192];
        size_t count = 0;
        LocalSendTLSOperationResult status;
        if (tls != nil) {
            status = [tls read:more length:sizeof(more) processed:&count];
            socket.wantsRead = [tls wantsRead];
        } else {
            count = sizeof(more);
            status = LocalSendReadPlainSocket(&socket, more, &count);
        }
        if (count > 0) {
            [pendingData appendBytes:more length:count];
            continue;
        }
        if (status != LocalSendTLSOperationCompleted && status != LocalSendTLSOperationWouldBlock) {
            return nil;
        }
        if (![self waitUntil:deadline]) {
            return nil;
        }
    }
    return nil;
}
- (BOOL)writeData:(NSData *)data {
    const unsigned char *bytes = [data bytes];
    NSUInteger offset = 0;
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + LocalSendReceiveIdleTimeout;
    while (offset < [data length] && ![server isInvalidated]) {
        size_t count = 0;
        LocalSendTLSOperationResult status;
        NSUInteger amount = MIN(LocalSendReceiveBufferSize, [data length] - offset);
        if (tls != nil) {
            status = [tls write:bytes + offset length:amount processed:&count];
            socket.wantsRead = [tls wantsRead];
        } else {
            count = amount;
            status = LocalSendWritePlainSocket(&socket, bytes + offset, &count);
        }
        if (count > 0) {
            offset += count;
            deadline = [NSDate timeIntervalSinceReferenceDate] + LocalSendReceiveIdleTimeout;
        }
        if (offset == [data length]) {
            return YES;
        }
        if (status != LocalSendTLSOperationCompleted && status != LocalSendTLSOperationWouldBlock) {
            return NO;
        }
        if (status == LocalSendTLSOperationWouldBlock && ![self waitUntil:deadline]) {
            return NO;
        }
    }
    return offset == [data length];
}
- (void)sendResponseWithStatus:(NSInteger)status body:(NSData *)body {
    if (status < 200 || status > 599) {
        status = 500;
    }
    if (body == nil) {
        NSDictionary *message = [NSDictionary dictionaryWithObject:LocalSendHTTPReasonPhrase(status)
                                                            forKey:@"message"];
        body = [LocalSendJSON dataWithJSONObject:message options:0 error:NULL];
    }
    if (status == 204) {
        body = [NSData data];
    }
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 %ld %@\r\nConnection: close\r\nContent-Type: "
                                                  @"application/json\r\nContent-Length: %lu\r\n\r\n",
                                                  (long)status, LocalSendHTTPReasonPhrase(status),
                                                  (unsigned long)[body length]];
    if ([self writeData:[header dataUsingEncoding:NSASCIIStringEncoding]]) {
        [self writeData:body];
    }
}
- (BOOL)startTLS:(SecIdentityRef)identity {
    if (identity == NULL) {
        return NO;
    }
    tls = [[LocalSendTLS alloc] initWithIdentity:identity socket:socket.socketDescriptor server:YES
                                       activity:activity];
    if (tls == nil) {
        [activity finishWithError:[LocalSendTLS lastInitializationError] ?: @"TLS context setup failed"];
        return NO;
    }
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 15.0;
    while (![server isInvalidated]) {
        LocalSendTLSOperationResult status = [tls handshake];
        socket.wantsRead = [tls wantsRead];
        if (status == LocalSendTLSOperationWouldBlock) {
            [activity setStage:socket.wantsRead ? @"Waiting for TLS read" : @"Waiting for TLS write"];
            if (![self waitUntil:deadline]) {
                [activity finishWithError:@"Incoming TLS handshake timed out or was cancelled"];
                return NO;
            }
            continue;
        }
        if (status != LocalSendTLSOperationCompleted) {
            NSLog(@"LocalSend receive TLS handshake failed: %@", [tls errorMessage]);
            [activity finishWithError:[tls errorMessage] ?: @"Peer closed the TLS handshake"];
            return NO;
        }
        // The wrapper requires a client certificate and verifies CertificateVerify.
        // Only then can its actual certificate fingerprint bind requests to a peer.
        [peerFingerprint release];
        peerFingerprint = [[tls peerFingerprint] copy];
        return [peerFingerprint length] == 64;
    }
    return NO;
}
- (BOOL)isOpen {
    if (socket.socketDescriptor < 0) {
        return NO;
    }
    unsigned char byte = 0;
    if (tls != nil && waitingForResponse) {
        // The request body is complete. A nonblocking read detects both TCP EOF
        // and an encrypted TLS close_notify while the user considers the offer.
        // Additional application bytes would be unsupported pipelining.
        size_t count = 0;
        LocalSendTLSOperationResult status = [tls read:&byte length:1 processed:&count];
        socket.wantsRead = [tls wantsRead];
        return count == 0 &&
               (status == LocalSendTLSOperationCompleted || status == LocalSendTLSOperationWouldBlock);
    }
    ssize_t count = recv(socket.socketDescriptor, &byte, 1, MSG_PEEK);
    if (count == 0) {
        return NO;
    }
    if (count > 0) {
        return !waitingForResponse;
    }
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
}

- (BOOL)prepareForRequestWithIdentity:(SecIdentityRef)identity {
    [activity setStage:@"Waiting for first request byte"];
    // Peek without consuming TLS bytes. HTTP metadata and TLS share the discovery port.
    unsigned char firstByte = 0;
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 15.0;
    while (YES) {
        ssize_t count = recv(socket.socketDescriptor, &firstByte, 1, MSG_PEEK);
        if (count == 1) {
            break;
        }
        if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            return NO;
        }
        socket.wantsRead = YES;
        if (![self waitUntil:deadline]) {
            return NO;
        }
    }
    BOOL secure = firstByte == 0x16;
    if (secure && ![self startTLS:identity]) {
        return NO;
    }
    if (!secure && (firstByte < 'A' || firstByte > 'Z')) {
        return NO;
    }
    return YES;
}

- (NSDictionary *)readRequest {
    return LocalSendReadHTTPRequest(self);
}
- (BOOL)readRequestBody:(NSDictionary *)request
               intoData:(NSMutableData *)body
               delegate:(id<LocalSendReceiveServerDelegate>)delegate
                 upload:(id)upload {
    return LocalSendReadHTTPRequestBody(self, request, body, delegate, upload);
}
@end
