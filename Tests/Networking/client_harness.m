#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "LocalSendHTTPSClient.h"
@interface ClientDelegate : NSObject <LocalSendHTTPSClientDelegate> {
  @public
    BOOL done;
    NSDictionary *result;
    NSUInteger lastProgress;
}
@end
@implementation ClientDelegate
- (void)httpsClient:(LocalSendHTTPSClient *)transport
    didCompleteWithStatus:(NSInteger)status
                     body:(NSData *)body {
    NSString *text = [[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] autorelease];
    result = [[NSDictionary alloc] initWithObjectsAndKeys:[NSNumber numberWithBool:YES], @"completed",
                                                          [NSNumber numberWithInteger:status], @"status",
                                                          text ?: @"", @"body",
                                                          [transport peerFingerprint] ?: @"", @"pin", nil];
    done = YES;
}
- (void)httpsClient:(LocalSendHTTPSClient *)transport didFailWithMessage:(NSString *)message {
    result = [[NSDictionary alloc] initWithObjectsAndKeys:[NSNumber numberWithBool:NO], @"completed", message,
                                                          @"error", [transport peerFingerprint] ?: @"",
                                                          @"pin", nil];
    done = YES;
}
- (void)httpsClient:(LocalSendHTTPSClient *)transport
    didSendBodyBytes:(NSUInteger)sent
          totalBytes:(NSUInteger)total {
    (void)transport;
    (void)total;
    lastProgress = sent;
}
- (void)dealloc {
    [result release];
    [super dealloc];
}
@end
int main(int argc, char **argv) {
    if (argc < 5) {
        return 2;
    }
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSData *pkcs12 = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
    NSDictionary *options =
        [NSDictionary dictionaryWithObjectsAndKeys:@"test-password", (id)kSecImportExportPassphrase,
                                                   (id)kCFBooleanTrue, (id)kSecImportToMemoryOnly, nil];
    CFArrayRef imported = NULL;
    OSStatus status = SecPKCS12Import((CFDataRef)pkcs12, (CFDictionaryRef)options, &imported);
    if (status != 0) {
        fprintf(stderr, "PKCS12 import=%ld\n", (long)status);
        return 1;
    }
    SecIdentityRef identity =
        (SecIdentityRef)[[(NSArray *)imported objectAtIndex:0] objectForKey:(id)kSecImportItemIdentity];
    ClientDelegate *delegate = [ClientDelegate new];
    NSString *expected = strcmp(argv[3], "-") == 0 ? nil : [NSString stringWithUTF8String:argv[3]];
    LocalSendHTTPSClient *transport =
        [[LocalSendHTTPSClient alloc] initWithHost:@"127.0.0.1"
                                              port:[NSNumber numberWithInt:atoi(argv[2])]
                                          identity:identity
                               expectedFingerprint:expected
                                          delegate:delegate];
    CFRelease(imported);
    if (strcmp(argv[4], "discovery") == 0) {
        [transport postDiscoveryBody:[@"private-discovery-data" dataUsingEncoding:NSUTF8StringEncoding]];
    } else if (argc > 5) {
        [transport postPath:@"/api/localsend/v2/upload"
                   bodyFile:[NSString stringWithUTF8String:argv[5]]
                contentType:@"application/octet-stream"];
    } else {
        [transport postPath:@"/api/localsend/v2/prepare-upload"
                       body:[@"private-transfer-data" dataUsingEncoding:NSUTF8StringEncoding]
                contentType:@"application/json"];
    }
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:12];
    while (!delegate->done && [limit timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    if (!delegate->done) {
        fprintf(stderr, "client test timeout\n");
        [transport invalidate];
        return 3;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:delegate->result options:0 error:NULL];
    fwrite([json bytes], 1, [json length], stdout);
    fputc('\n', stdout);
    fflush(stdout);
    [transport invalidate];
    [transport release];
    [delegate release];
    [pool drain];
    return 0;
}
