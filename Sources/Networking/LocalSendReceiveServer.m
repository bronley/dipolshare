#import "LocalSendReceiveServer.h"
#import "LocalSendIncomingConnection.h"
#import <errno.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <unistd.h>

static const NSUInteger LocalSendMaximumJSONBodyLength = 1024 * 1024;
static NSString *const LocalSendCurrentConnectionThreadKey = @"LocalSendReceiveServer.currentConnection";

@interface LocalSendReceiveServer ()
- (BOOL)isInvalidated;
- (void)runConnection:(LocalSendIncomingConnection *)connection;
@end

@implementation LocalSendReceiveServer
- (id)initWithIdentity:(SecIdentityRef)identity delegate:(id<LocalSendReceiveServerDelegate>)delegate {
    self = [super init];
    if (self) {
        if (identity != NULL) {
            _identity = (SecIdentityRef)CFRetain(identity);
        }
        _delegate = [delegate retain];
        _connections = [[NSMutableSet alloc] init];
    }
    return self;
}
- (void)dealloc {
    if (_identity != NULL) {
        CFRelease(_identity);
    }
    [_delegate release];
    [_connections release];
    [super dealloc];
}
- (BOOL)isInvalidated {
    @synchronized(self) {
        return _invalidated;
    }
}
- (BOOL)isCurrentConnectionOpen {
    if ([self isInvalidated]) {
        return NO;
    }
    LocalSendIncomingConnection *connection =
        [[[NSThread currentThread] threadDictionary] objectForKey:LocalSendCurrentConnectionThreadKey];
    if (connection == nil || connection->server != self) {
        return YES;
    }
    return [connection isOpen];
}
- (void)acceptSocket:(int)socketDescriptor address:(NSString *)address {
    if (socketDescriptor < 0) {
        return;
    }
    LocalSendIncomingConnection *connection = [[LocalSendIncomingConnection alloc] init];
    connection->socket.socketDescriptor = socketDescriptor;
    connection->address = [address copy];
    connection->server = self;
    @synchronized(self) {
        if (_invalidated || [_connections count] >= 8 || socketDescriptor >= FD_SETSIZE) {
            close(socketDescriptor);
            [connection release];
            return;
        }
        int flags = fcntl(socketDescriptor, F_GETFL, 0), enabled = 1;
        if (flags < 0 || fcntl(socketDescriptor, F_SETFL, flags | O_NONBLOCK) < 0 ||
            setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0) {
            close(socketDescriptor);
            [connection release];
            return;
        }
        [_connections addObject:connection];
        [NSThread detachNewThreadSelector:@selector(runConnection:) toTarget:self withObject:connection];
    }
    [connection release];
}
- (void)invalidate {
    id delegate = nil;
    @synchronized(self) {
        if (_invalidated) {
            return;
        }
        _invalidated = YES;
        LocalSendIncomingConnection *connection;
        for (connection in _connections) {
            shutdown(connection->socket.socketDescriptor, SHUT_RDWR);
        }
        delegate = _delegate;
        _delegate = nil;
    }
    [delegate release];
}
- (void)runConnection:(LocalSendIncomingConnection *)connection {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    id<LocalSendReceiveServerDelegate> delegate = nil;
    id upload = nil;
    @synchronized(self) {
        delegate = [_delegate retain];
    }
    [[[NSThread currentThread] threadDictionary] setObject:connection
                                                    forKey:LocalSendCurrentConnectionThreadKey];
    @try {
        if (delegate == nil || [self isInvalidated]) {
            goto finished;
        }
        if (![connection prepareForRequestWithIdentity:_identity]) {
            goto finished;
        }
        BOOL secure = connection->tls != nil;
        NSDictionary *request = [connection readRequest];
        if (request == nil) {
            [connection sendResponseWithStatus:connection->errorStatus body:nil];
            goto finished;
        }
        NSString *method = [request objectForKey:@"method"], *target = [request objectForKey:@"target"];
        NSDictionary *headers = [request objectForKey:@"headers"];
        NSString *path = [[target componentsSeparatedByString:@"?"] objectAtIndex:0];
        BOOL metadata =
            ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/localsend/v2/info"]) ||
            ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/localsend/v2/register"]);
        if (!secure && !metadata) {
            [connection sendResponseWithStatus:426 body:nil];
            goto finished;
        }
        NSMutableDictionary *peer = [NSMutableDictionary
            dictionaryWithObjectsAndKeys:connection->address != nil ? connection->address : @"", @"address",
                                         secure ? @"https" : @"http", @"protocol", nil];
        if (secure) {
            [peer setObject:connection->peerFingerprint forKey:@"fingerprint"];
        }
        BOOL isUpload =
            [method isEqualToString:@"POST"] && [path isEqualToString:@"/api/localsend/v2/upload"];
        if (isUpload) {
            if ([headers objectForKey:@"content-length"] == nil &&
                ![[request objectForKey:@"chunked"] boolValue]) {
                [connection sendResponseWithStatus:411 body:nil];
                goto finished;
            }
            NSInteger status = 403;
            if ([self isInvalidated]) {
                goto finished;
            }
            upload = [[delegate receiveServer:self
                          beginUploadToTarget:target
                                      headers:headers
                                         peer:peer
                                  errorStatus:&status] retain];
            if (upload == nil) {
                [connection sendResponseWithStatus:status body:nil];
                goto finished;
            }
        } else if (![[request objectForKey:@"chunked"] boolValue] &&
                   [[request objectForKey:@"length"] unsignedLongLongValue] >
                       LocalSendMaximumJSONBodyLength) {
            [connection sendResponseWithStatus:413 body:nil];
            goto finished;
        }
        if ([headers objectForKey:@"expect"] != nil &&
            ![connection
                writeData:[@"HTTP/1.1 100 Continue\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding]]) {
            goto finished;
        }
        NSMutableData *body = isUpload ? nil : [NSMutableData data];
        if (![connection readRequestBody:request intoData:body delegate:delegate upload:upload]) {
            [connection sendResponseWithStatus:connection->errorStatus body:nil];
            goto finished;
        }
        if ([self isInvalidated]) {
            goto finished;
        }
        if (isUpload) {
            NSInteger status = [delegate receiveServer:self finishUpload:upload];
            // Finish owns final commit/error cleanup. Abort is reserved for incomplete input.
            [upload release];
            upload = nil;
            [connection sendResponseWithStatus:status body:[NSData data]];
        } else {
            connection->waitingForResponse = YES;
            NSDictionary *response = [delegate receiveServer:self
                                           responseForMethod:method
                                                      target:target
                                                     headers:headers
                                                        body:body
                                                        peer:peer];
            connection->waitingForResponse = NO;
            id status = [response objectForKey:@"status"], data = [response objectForKey:@"body"];
            [connection sendResponseWithStatus:[status respondsToSelector:@selector(integerValue)]
                                                   ? [status integerValue]
                                                   : 500
                                          body:[data isKindOfClass:[NSData class]] ? data : nil];
        }
    finished:;
    } @catch (NSException *exception) {
        NSLog(@"LocalSend receive connection stopped (%@)", [exception name]);
        [connection sendResponseWithStatus:500 body:nil];
    } @finally {
        if (upload != nil) {
            [delegate receiveServer:self abortUpload:upload];
            [upload release];
        }
        [connection->tls close];
        @synchronized(self) {
            shutdown(connection->socket.socketDescriptor, SHUT_RDWR);
            close(connection->socket.socketDescriptor);
            connection->socket.socketDescriptor = -1;
            [_connections removeObject:connection];
        }
        [[[NSThread currentThread] threadDictionary] removeObjectForKey:LocalSendCurrentConnectionThreadKey];
        [delegate release];
        [pool drain];
    }
}
@end
