#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <arpa/inet.h>
#import "LocalSendReceiveServer.h"
@interface HarnessDelegate : NSObject <LocalSendReceiveServerDelegate> {
    NSUInteger _began, _finished, _aborted, _maxBlock, _disconnects;
}
@end
@implementation HarnessDelegate
- (NSDictionary *)receiveServer:(LocalSendReceiveServer *)server
              responseForMethod:(NSString *)method
                         target:(NSString *)target
                        headers:(NSDictionary *)headers
                           body:(NSData *)body
                           peer:(NSDictionary *)peer {
    if ([target isEqualToString:@"/await-approval"]) {
        for (NSUInteger attempt = 0; attempt < 100; attempt++) {
            if (![server isCurrentConnectionOpen]) {
                @synchronized(self) {
                    _disconnects++;
                }
                break;
            }
            [NSThread sleepForTimeInterval:0.01];
        }
    }
    if ([target isEqualToString:@"/invalidate"]) {
        [server invalidate];
    }
    if ([target isEqualToString:@"/api/localsend/v2/info"]) {
        @synchronized(self) {
            NSDictionary *info = [NSDictionary
                dictionaryWithObjectsAndKeys:[NSNumber numberWithUnsignedInteger:_began], @"began",
                                             [NSNumber numberWithUnsignedInteger:_disconnects],
                                             @"disconnects", [NSNumber numberWithUnsignedInteger:_finished],
                                             @"finished", [NSNumber numberWithUnsignedInteger:_aborted],
                                             @"aborted", [NSNumber numberWithUnsignedInteger:_maxBlock],
                                             @"maxBlock", peer, @"peer", nil];
            body = [NSJSONSerialization dataWithJSONObject:info options:0 error:NULL];
        }
    }
    return [NSDictionary
        dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:200], @"status", body, @"body", nil];
}
- (id)receiveServer:(LocalSendReceiveServer *)server
    beginUploadToTarget:(NSString *)target
                headers:(NSDictionary *)headers
                   peer:(NSDictionary *)peer
            errorStatus:(NSInteger *)status {
    if (![target hasPrefix:@"/api/localsend/v2/upload?token=ok&size="]) {
        *status = 403;
        return nil;
    }
    unsigned long long length = [[[target componentsSeparatedByString:@"size="] lastObject] longLongValue];
    @synchronized(self) {
        _began++;
    }
    return [NSMutableDictionary dictionaryWithObjectsAndKeys:[NSMutableData data], @"data",
                                                             [NSNumber numberWithUnsignedLongLong:length],
                                                             @"length", nil];
}
- (BOOL)receiveServer:(LocalSendReceiveServer *)server upload:(id)upload appendData:(NSData *)data {
    @synchronized(self) {
        _maxBlock = MAX(_maxBlock, [data length]);
    }
    NSMutableData *accumulated = [upload objectForKey:@"data"];
    [accumulated appendData:data];
    return [accumulated length] <= [[upload objectForKey:@"length"] unsignedLongLongValue];
}
- (NSInteger)receiveServer:(LocalSendReceiveServer *)server finishUpload:(id)upload {
    @synchronized(self) {
        _finished++;
    }
    return [[upload objectForKey:@"data"] length] == [[upload objectForKey:@"length"] unsignedLongLongValue]
               ? 200
               : 422;
}
- (void)receiveServer:(LocalSendReceiveServer *)server abortUpload:(id)upload {
    @synchronized(self) {
        _aborted++;
    }
}
@end
int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: transport_harness identity.p12\n");
        return 2;
    }
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSData *pkcs12 = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
    CFArrayRef imported = NULL;
    NSDictionary *options =
        [NSDictionary dictionaryWithObjectsAndKeys:@"test-password", (id)kSecImportExportPassphrase,
                                                   (id)kCFBooleanTrue, (id)kSecImportToMemoryOnly, nil];
    OSStatus status = SecPKCS12Import((CFDataRef)pkcs12, (CFDictionaryRef)options, &imported);
    if (status != 0) {
        fprintf(stderr, "PKCS12 import=%ld\n", (long)status);
        return 1;
    }
    SecIdentityRef identity =
        (SecIdentityRef)[[(NSArray *)imported objectAtIndex:0] objectForKey:(id)kSecImportItemIdentity];
    HarnessDelegate *delegate = [[HarnessDelegate alloc] init];
    LocalSendReceiveServer *server = [[LocalSendReceiveServer alloc] initWithIdentity:identity
                                                                             delegate:delegate];
    CFRelease(imported);
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 16)) {
        perror("listen");
        return 1;
    }
    socklen_t length = sizeof(address);
    getsockname(listener, (struct sockaddr *)&address, &length);
    printf("%u\n", ntohs(address.sin_port));
    fflush(stdout);
    while (YES) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) {
            break;
        }
        [server acceptSocket:fd address:@"127.0.0.1"];
    }
    [server invalidate];
    [server release];
    [delegate release];
    [pool drain];
    return 0;
}
