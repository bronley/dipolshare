#import "LocalSendHTTPSClient.h"
#import "LocalSendTLS.h"
#import "LocalSendHTTPResponseParser.h"
#import "LocalSendCertificateFingerprint.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netdb.h>
#import <netinet/in.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <unistd.h>

static const NSTimeInterval kLocalSendConnectTimeout = 15.0;
static const NSTimeInterval kLocalSendTLSHandshakeTimeout = 30.0;
static const NSTimeInterval kLocalSendIOTimeout = 60.0;

static int LocalSendWaitForSocket(int socketDescriptor, BOOL wantsRead, NSTimeInterval timeout) {
    fd_set readSet;
    fd_set writeSet;
    FD_ZERO(&readSet);
    FD_ZERO(&writeSet);
    if (wantsRead) {
        FD_SET(socketDescriptor, &readSet);
    } else {
        FD_SET(socketDescriptor, &writeSet);
    }
    struct timeval interval;
    interval.tv_sec = (int)timeout;
    interval.tv_usec = (int)((timeout - interval.tv_sec) * 1000000.0);
    return select(socketDescriptor + 1, &readSet, &writeSet, NULL, &interval);
}

@interface LocalSendHTTPSClient ()
- (void)postPath:(NSString *)path
            body:(NSData *)body
        bodyFile:(NSString *)filePath
     contentType:(NSString *)contentType;
- (void)runRequest:(NSDictionary *)request;
- (void)deliverFailure:(NSString *)message;
- (void)deliverResult:(NSDictionary *)result;
- (void)deliverProgress:(NSDictionary *)progress;
- (void)reportFailure:(NSString *)message;
- (void)reportResultStatus:(NSInteger)status body:(NSData *)body;
- (void)reportProgressSent:(NSUInteger)sent total:(NSUInteger)total;
- (int)connectSocketWithError:(NSString **)errorMessage;
- (BOOL)waitForTLS:(int)socketDescriptor
               tls:(LocalSendTLS *)tls
          deadline:(NSTimeInterval)deadline
             error:(NSString **)errorMessage;
- (BOOL)writeData:(NSData *)data
             context:(LocalSendTLS *)context
    socketDescriptor:(int)socketDescriptor
            progress:(BOOL)progress
               error:(NSString **)errorMessage;
- (NSData *)readResponseWithContext:(LocalSendTLS *)context
                   socketDescriptor:(int)socketDescriptor
                            timeout:(NSTimeInterval)timeout
                              error:(NSString **)errorMessage;
- (BOOL)parseResponse:(NSData *)response
               status:(NSInteger *)status
                 body:(NSData **)body
                error:(NSString **)errorMessage;
@end

@implementation LocalSendHTTPSClient

- (id)initWithHost:(NSString *)host
                   port:(NSNumber *)port
               identity:(SecIdentityRef)identity
    expectedFingerprint:(NSString *)expectedFingerprint
               delegate:(id<LocalSendHTTPSClientDelegate>)delegate {
    self = [super init];
    if (self) {
        _host = [host copy];
        _port = [port retain];
        _expectedFingerprint = [expectedFingerprint copy];
        _identity = identity;
        if (_identity != NULL) {
            CFRetain(_identity);
        }
        _delegate = delegate;
    }
    return self;
}

- (NSString *)peerFingerprint {
    @synchronized(self) {
        return [[_peerFingerprint retain] autorelease];
    }
}

- (void)postDiscoveryBody:(NSData *)body {
    @synchronized(self) {
        if (_running || _cancelled) {
            return;
        }
    }
    _discoveryOnly = YES;
    _discoveryDeadline = [NSDate timeIntervalSinceReferenceDate] + 4.0;
    [self postPath:@"/api/localsend/v2/register" body:body contentType:@"application/json"];
}

- (void)postPath:(NSString *)path body:(NSData *)body contentType:(NSString *)contentType {
    [self postPath:path body:body bodyFile:nil contentType:contentType];
}

- (void)postPath:(NSString *)path bodyFile:(NSString *)filePath contentType:(NSString *)contentType {
    [self postPath:path body:nil bodyFile:filePath contentType:contentType];
}

- (void)postPath:(NSString *)path
            body:(NSData *)body
        bodyFile:(NSString *)filePath
     contentType:(NSString *)contentType {
    // Never allow the discovery trust policy on an upload or another API.
    if (_discoveryOnly && ![path isEqualToString:@"/api/localsend/v2/register"]) {
        return;
    }
    @synchronized(self) {
        if (_running || _cancelled) {
            return;
        }
        _running = YES;
    }

    NSMutableDictionary *request =
        [NSMutableDictionary dictionaryWithObjectsAndKeys:path, @"path", contentType, @"contentType", nil];
    if (body != nil) {
        [request setObject:body forKey:@"body"];
    }
    if (filePath != nil) {
        [request setObject:filePath forKey:@"bodyFile"];
    }
    [NSThread detachNewThreadSelector:@selector(runRequest:) toTarget:self withObject:request];
}

- (void)invalidate {
    @synchronized(self) {
        _cancelled = YES;
        _delegate = nil;
    }
}

- (BOOL)isCancelled {
    @synchronized(self) {
        return _cancelled;
    }
}

- (int)connectSocketWithError:(NSString **)errorMessage {
    char portString[16];
    snprintf(portString, sizeof(portString), "%u", [_port unsignedIntValue]);

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;

    struct addrinfo *addresses = NULL;
    int lookup = getaddrinfo([_host UTF8String], portString, &hints, &addresses);
    if (lookup != 0) {
        *errorMessage = [NSString stringWithFormat:@"DNS/address lookup failed for %@:%@ (%s).", _host, _port,
                                                   gai_strerror(lookup)];
        return -1;
    }

    int connectedSocket = -1;
    int lastSocketError = 0;
    struct addrinfo *address;
    for (address = addresses; address != NULL; address = address->ai_next) {
        int socketDescriptor = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (socketDescriptor < 0) {
            lastSocketError = errno;
            continue;
        }
        if (socketDescriptor >= FD_SETSIZE) {
            lastSocketError = EMFILE;
            close(socketDescriptor);
            continue;
        }

        int noSigPipe = 1;
        setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        int flags = fcntl(socketDescriptor, F_GETFL, 0);
        if (flags < 0 || fcntl(socketDescriptor, F_SETFL, flags | O_NONBLOCK) < 0) {
            lastSocketError = errno;
            close(socketDescriptor);
            continue;
        }

        int result = connect(socketDescriptor, address->ai_addr, address->ai_addrlen);
        if (result < 0 && errno == EINPROGRESS) {
            fd_set writeSet;
            FD_ZERO(&writeSet);
            FD_SET(socketDescriptor, &writeSet);
            struct timeval timeout;
            timeout.tv_sec = _discoveryOnly ? 1 : (int)kLocalSendConnectTimeout;
            timeout.tv_usec = 0;
            do {
                result = select(socketDescriptor + 1, NULL, &writeSet, NULL, &timeout);
            } while (result < 0 && errno == EINTR);
            if (result > 0) {
                socklen_t errorLength = sizeof(lastSocketError);
                if (getsockopt(socketDescriptor, SOL_SOCKET, SO_ERROR, &lastSocketError, &errorLength) == 0 &&
                    lastSocketError == 0) {
                    result = 0;
                } else {
                    result = -1;
                }
            } else {
                lastSocketError = result == 0 ? ETIMEDOUT : errno;
                result = -1;
            }
        }

        if (result == 0) {
            connectedSocket = socketDescriptor;
            break;
        }
        if (lastSocketError == 0) {
            lastSocketError = errno;
        }
        close(socketDescriptor);
    }
    freeaddrinfo(addresses);

    if (connectedSocket < 0) {
        *errorMessage = [NSString stringWithFormat:@"TCP connection to %@:%@ failed (%s).", _host, _port,
                                                   strerror(lastSocketError)];
    }
    return connectedSocket;
}

- (BOOL)waitForTLS:(int)socketDescriptor
               tls:(LocalSendTLS *)tls
          deadline:(NSTimeInterval)deadline
             error:(NSString **)errorMessage {
    if (_discoveryOnly) {
        deadline = MIN(deadline, _discoveryDeadline);
    }
    while (![self isCancelled]) {
        NSTimeInterval remaining = deadline - [NSDate timeIntervalSinceReferenceDate];
        if (remaining <= 0) {
            *errorMessage = [tls wantsRead] ? @"Timed out waiting for TLS data from the receiver."
                                            : @"Timed out writing TLS data to the receiver.";
            return NO;
        }
        // Brief waits make cancellation responsive without changing the deadline.
        int result = LocalSendWaitForSocket(socketDescriptor, [tls wantsRead], MIN(remaining, 0.25));
        if (result > 0) {
            return YES;
        }
        if (result < 0 && errno != EINTR) {
            *errorMessage = [NSString stringWithFormat:@"TLS socket wait failed (%s).", strerror(errno)];
            return NO;
        }
    }
    *errorMessage = @"Transfer cancelled.";
    return NO;
}

- (BOOL)writeData:(NSData *)data
             context:(LocalSendTLS *)context
    socketDescriptor:(int)socketDescriptor
            progress:(BOOL)progress
               error:(NSString **)errorMessage {
    const unsigned char *bytes = [data bytes];
    NSUInteger total = [data length];
    NSUInteger offset = 0;
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + kLocalSendIOTimeout;

    while (offset < total) {
        if ([self isCancelled] ||
            (_discoveryOnly && [NSDate timeIntervalSinceReferenceDate] >= _discoveryDeadline)) {
            *errorMessage = @"Transfer cancelled.";
            return NO;
        }
        size_t processed = 0;
        LocalSendTLSOperationResult status = [context write:bytes + offset
                                                     length:total - offset
                                                  processed:&processed];
        offset += processed;
        if (processed > 0) {
            deadline = [NSDate timeIntervalSinceReferenceDate] + kLocalSendIOTimeout;
            if (progress) {
                [self reportProgressSent:offset total:total];
            }
        }
        if (status == LocalSendTLSOperationCompleted) {
            continue;
        }
        if (status == LocalSendTLSOperationWouldBlock) {
            if (![self waitForTLS:socketDescriptor tls:context deadline:deadline error:errorMessage]) {
                return NO;
            }
            continue;
        }
        *errorMessage =
            [NSString stringWithFormat:@"TLS write failed after %lu of %lu bytes (%@).",
                                       (unsigned long)offset, (unsigned long)total,
                                       [context errorMessage] ?: @"receiver closed the connection"];
        return NO;
    }
    return YES;
}

- (BOOL)writeFile:(NSString *)path
              length:(unsigned long long)length
             context:(LocalSendTLS *)context
    socketDescriptor:(int)socketDescriptor
               error:(NSString **)errorMessage {
    int fileDescriptor = open([path fileSystemRepresentation], O_RDONLY);
    if (fileDescriptor < 0) {
        *errorMessage = @"Could not open the selected photo.";
        return NO;
    }
    unsigned char bytes[32768];
    unsigned long long sent = 0;
    BOOL succeeded = YES;
    while (sent < length) {
        if ([self isCancelled]) {
            *errorMessage = @"Transfer cancelled.";
            succeeded = NO;
            break;
        }
        NSUInteger wanted = (NSUInteger)MIN((unsigned long long)sizeof(bytes), length - sent);
        ssize_t count = read(fileDescriptor, bytes, wanted);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            *errorMessage = @"The selected photo became unavailable during upload.";
            succeeded = NO;
            break;
        }
        NSData *piece = [NSData dataWithBytesNoCopy:bytes length:(NSUInteger)count freeWhenDone:NO];
        if (![self writeData:piece
                         context:context
                socketDescriptor:socketDescriptor
                        progress:NO
                           error:errorMessage]) {
            succeeded = NO;
            break;
        }
        sent += (unsigned long long)count;
        [self reportProgressSent:(NSUInteger)sent total:(NSUInteger)length];
    }
    close(fileDescriptor);
    return succeeded;
}

- (NSData *)readResponseWithContext:(LocalSendTLS *)context
                   socketDescriptor:(int)socketDescriptor
                            timeout:(NSTimeInterval)timeout
                              error:(NSString **)errorMessage {
    NSMutableData *response = [NSMutableData data];
    unsigned char buffer[16384];
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + timeout;
    while (YES) {
        if ([self isCancelled] ||
            (_discoveryOnly && [NSDate timeIntervalSinceReferenceDate] >= _discoveryDeadline)) {
            *errorMessage = @"Transfer cancelled.";
            return nil;
        }
        size_t processed = 0;
        LocalSendTLSOperationResult status = [context read:buffer length:sizeof(buffer) processed:&processed];
        if (processed > 0) {
            [response appendBytes:buffer length:processed];
            if (_discoveryOnly && [response length] > 65536) {
                *errorMessage = @"Discovery response is too large.";
                return nil;
            }
            deadline = [NSDate timeIntervalSinceReferenceDate] + timeout;
        }
        // OpenSSL rejects a bare TCP EOF. Complete explicit HTTP framing does
        // not need EOF; a close-delimited response requires TLS close_notify.
        if (processed > 0 || status == LocalSendTLSConnectionClosed) {
            NSInteger responseStatus = 0;
            LocalSendHTTPResponseParseResult parsed = LocalSendParseHTTPResponse(
                response, status == LocalSendTLSConnectionClosed, &responseStatus, NULL, errorMessage);
            if (parsed == LocalSendHTTPResponseInvalid) {
                return nil;
            }
            if (parsed == LocalSendHTTPResponseComplete) {
                return response;
            }
        }
        if (status == LocalSendTLSOperationCompleted) {
            continue;
        }
        if (status == LocalSendTLSOperationWouldBlock) {
            if (![self waitForTLS:socketDescriptor tls:context deadline:deadline error:errorMessage]) {
                return nil;
            }
            continue;
        }
        *errorMessage =
            [NSString stringWithFormat:@"TLS read failed after %lu response bytes (%@).",
                                       (unsigned long)[response length],
                                       [context errorMessage] ?: @"receiver closed an incomplete response"];
        return nil;
    }
}

- (BOOL)parseResponse:(NSData *)response
               status:(NSInteger *)status
                 body:(NSData **)body
                error:(NSString **)errorMessage {
    return LocalSendParseHTTPResponse(response, YES, status, body, errorMessage) ==
           LocalSendHTTPResponseComplete;
}

- (BOOL)performTLSHandshake:(LocalSendTLS *)context
           socketDescriptor:(int)socketDescriptor
                      error:(NSString **)errorMessage {
    NSTimeInterval handshakeDeadline =
        [NSDate timeIntervalSinceReferenceDate] + kLocalSendTLSHandshakeTimeout;
    while (YES) {
        if ([self isCancelled]) {
            *errorMessage = @"Transfer cancelled.";
            return NO;
        }
        LocalSendTLSOperationResult status = [context handshake];
        if (status == LocalSendTLSOperationWouldBlock) {
            if (![self waitForTLS:socketDescriptor
                              tls:context
                         deadline:handshakeDeadline
                            error:errorMessage]) {
                return NO;
            }
            continue;
        }
        if (status != LocalSendTLSOperationCompleted) {
            *errorMessage =
                [NSString stringWithFormat:@"Mutual TLS handshake failed (%@).",
                                           [context errorMessage] ?: @"receiver closed the connection"];
            return NO;
        }
        break;
    }
    return YES;
}

- (BOOL)verifyPeerFingerprint:(LocalSendTLS *)context error:(NSString **)errorMessage {
    // Check the peer only after a complete handshake, before any HTTP bytes.
    // Unknown discovery can learn a pin; transfer requests always require one.
    NSString *actualFingerprint = [context peerFingerprint];
    if (!LocalSendPeerFingerprintMatches(_expectedFingerprint, actualFingerprint, _discoveryOnly)) {
        *errorMessage =
            @"Receiver certificate fingerprint is missing, invalid or does not match the discovered device.";
        return NO;
    }
    @synchronized(self) {
        [_peerFingerprint release];
        _peerFingerprint = [actualFingerprint copy];
    }

    return YES;
}

- (BOOL)writeRequest:(NSDictionary *)request
             context:(LocalSendTLS *)context
    socketDescriptor:(int)socketDescriptor
               error:(NSString **)errorMessage {
    NSString *path = [request objectForKey:@"path"];
    NSData *body = [request objectForKey:@"body"];
    NSString *bodyFile = [request objectForKey:@"bodyFile"];
    NSDictionary *fileAttributes =
        bodyFile != nil ? [[NSFileManager defaultManager] attributesOfItemAtPath:bodyFile error:NULL] : nil;
    if (bodyFile != nil && fileAttributes == nil) {
        *errorMessage = @"The selected photo is no longer available.";
        return NO;
    }
    unsigned long long bodyLength =
        bodyFile != nil ? [[fileAttributes objectForKey:NSFileSize] unsignedLongLongValue] : [body length];
    NSString *contentType = [request objectForKey:@"contentType"];
    NSString *headers = [NSString stringWithFormat:@"POST %@ HTTP/1.1\r\n"
                                                    "Host: %@:%@\r\n"
                                                    "Content-Type: %@\r\n"
                                                    "Content-Length: %llu\r\n"
                                                    "Connection: close\r\n"
                                                    "User-Agent: LocalSend-iOS5/2.0\r\n\r\n",
                                                   path, _host, _port, contentType, bodyLength];
    NSData *headerData = [headers dataUsingEncoding:NSUTF8StringEncoding];

    if (![self writeData:headerData
                     context:context
            socketDescriptor:socketDescriptor
                    progress:NO
                       error:errorMessage]) {
        return NO;
    }
    if (bodyFile != nil) {
        if (![self writeFile:bodyFile
                          length:bodyLength
                         context:context
                socketDescriptor:socketDescriptor
                           error:errorMessage]) {
            return NO;
        }
    } else if (![self writeData:body
                            context:context
                   socketDescriptor:socketDescriptor
                           progress:YES
                              error:errorMessage]) {
        return NO;
    }

    return YES;
}

- (void)runRequest:(NSDictionary *)request {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *errorMessage = nil;
    int socketDescriptor = -1;
    LocalSendTLS *context = nil;

    if (_identity == NULL) {
        errorMessage = @"TLS client identity is unavailable; mutual TLS cannot start.";
        goto cleanup;
    }

    socketDescriptor = [self connectSocketWithError:&errorMessage];
    if (socketDescriptor < 0) {
        goto cleanup;
    }

    context = [[LocalSendTLS alloc] initWithIdentity:_identity socket:socketDescriptor server:NO];
    if (context == nil) {
        errorMessage = @"Could not create the app TLS context.";
        goto cleanup;
    }
    if (![self performTLSHandshake:context socketDescriptor:socketDescriptor error:&errorMessage]) {
        goto cleanup;
    }
    if (![self verifyPeerFingerprint:context error:&errorMessage]) {
        goto cleanup;
    }
    if (![self writeRequest:request context:context socketDescriptor:socketDescriptor error:&errorMessage]) {
        goto cleanup;
    }

    NSString *path = [request objectForKey:@"path"];
    NSTimeInterval responseTimeout =
        [path isEqualToString:@"/api/localsend/v2/prepare-upload"] ? 130.0 : kLocalSendIOTimeout;
    NSData *response = [self readResponseWithContext:context
                                    socketDescriptor:socketDescriptor
                                             timeout:responseTimeout
                                               error:&errorMessage];
    if (response == nil) {
        goto cleanup;
    }

    NSInteger responseStatus = 0;
    NSData *responseBody = nil;
    if (![self parseResponse:response status:&responseStatus body:&responseBody error:&errorMessage]) {
        goto cleanup;
    }
    [self reportResultStatus:responseStatus body:responseBody];

cleanup:
    if (errorMessage != nil && ![self isCancelled]) {
        [self reportFailure:errorMessage];
    }
    [context close];
    [context release];
    if (socketDescriptor >= 0) {
        close(socketDescriptor);
    }
    @synchronized(self) {
        _running = NO;
    }
    [pool drain];
}

- (void)reportFailure:(NSString *)message {
    [self performSelectorOnMainThread:@selector(deliverFailure:) withObject:message waitUntilDone:NO];
}

- (void)reportResultStatus:(NSInteger)status body:(NSData *)body {
    NSDictionary *result =
        [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInteger:status], @"status",
                                                   body != nil ? body : [NSData data], @"body", nil];
    [self performSelectorOnMainThread:@selector(deliverResult:) withObject:result waitUntilDone:NO];
}

- (void)reportProgressSent:(NSUInteger)sent total:(NSUInteger)total {
    NSDictionary *progress =
        [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithUnsignedInteger:sent], @"sent",
                                                   [NSNumber numberWithUnsignedInteger:total], @"total", nil];
    [self performSelectorOnMainThread:@selector(deliverProgress:) withObject:progress waitUntilDone:NO];
}

- (void)deliverFailure:(NSString *)message {
    id<LocalSendHTTPSClientDelegate> delegate = nil;
    @synchronized(self) {
        delegate = _delegate;
    }
    if (delegate != nil) {
        [delegate httpsClient:self didFailWithMessage:message];
    }
}

- (void)deliverResult:(NSDictionary *)result {
    id<LocalSendHTTPSClientDelegate> delegate = nil;
    @synchronized(self) {
        delegate = _delegate;
    }
    if (delegate != nil) {
        [delegate httpsClient:self
            didCompleteWithStatus:[[result objectForKey:@"status"] integerValue]
                             body:[result objectForKey:@"body"]];
    }
}

- (void)deliverProgress:(NSDictionary *)progress {
    id<LocalSendHTTPSClientDelegate> delegate = nil;
    @synchronized(self) {
        delegate = _delegate;
    }
    if (delegate != nil) {
        [delegate httpsClient:self
             didSendBodyBytes:[[progress objectForKey:@"sent"] unsignedIntegerValue]
                   totalBytes:[[progress objectForKey:@"total"] unsignedIntegerValue]];
    }
}

- (void)dealloc {
    [self invalidate];
    [_host release];
    [_port release];
    [_expectedFingerprint release];
    [_peerFingerprint release];
    if (_identity != NULL) {
        CFRelease(_identity);
    }
    [super dealloc];
}

@end
