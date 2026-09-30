#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "LocalSendHTTPSClient.h"
#undef SecKeyRawSign
extern OSStatus SecKeyRawSign(SecKeyRef key, SecPadding padding, const uint8_t *data,
                              size_t length, uint8_t *signature, size_t *signatureLength);
static NSCondition *signingGate;
static BOOL holdSigning, enteredSigning, releaseSigning;
static NSUInteger signingCalls;
OSStatus LocalSendTestSecKeyRawSign(SecKeyRef key, SecPadding padding, const uint8_t *data,
                                    size_t length, uint8_t *signature, size_t *signatureLength) {
    [signingGate lock];
    signingCalls++;
    enteredSigning = YES;
    while (holdSigning && !releaseSigning) [signingGate wait];
    [signingGate unlock];
    return SecKeyRawSign(key, padding, data, length, signature, signatureLength);
}
static BOOL SigningHasEntered(void) {
    [signingGate lock];
    BOOL entered = enteredSigning;
    [signingGate unlock];
    return entered;
}
@interface ClientDelegate : NSObject <LocalSendHTTPSClientDelegate> {
  @public
    BOOL done;
    NSDictionary *result;
    unsigned long long lastProgress;
    unsigned long long lastTotal;
    NSUInteger progressCount;
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
                                                          @"pin", [transport diagnosticStatus], @"diagnostic", nil];
    done = YES;
}
- (void)httpsClient:(LocalSendHTTPSClient *)transport
    didSendBodyBytes:(unsigned long long)sent
          totalBytes:(unsigned long long)total {
    (void)transport;
    lastProgress = sent;
    lastTotal = total;
    progressCount++;
}
- (void)dealloc {
    [result release];
    [super dealloc];
}
@end

@interface LocalSendHTTPSClient (ProgressTests)
- (void)reportProgressSent:(unsigned long long)sent total:(unsigned long long)total;
@end
@interface ProgressProducer : NSObject {
  @public
    LocalSendHTTPSClient *client;
    NSCondition *condition;
    BOOL finished;
}
- (void)run;
@end
@implementation ProgressProducer
- (void)run {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    unsigned long long total = 5ULL * 1024 * 1024 * 1024;
    for (NSUInteger i = 0; i < 20000; i++) {
        [client reportProgressSent:(total * i) / 20000 total:total];
    }
    [client reportProgressSent:total total:total];
    [pool drain];
    [condition lock];
    finished = YES;
    [condition signal];
    [condition unlock];
}
@end

static int TestProgressBackpressure(void) {
    ClientDelegate *delegate = [ClientDelegate new];
    LocalSendHTTPSClient *client = [[LocalSendHTTPSClient alloc] initWithHost:@"127.0.0.1" port:@1
        identity:NULL expectedFingerprint:nil delegate:delegate];
    ProgressProducer *producer = [ProgressProducer new];
    producer->client = client;
    producer->condition = [NSCondition new];
    [producer->condition lock];
    [NSThread detachNewThreadSelector:@selector(run) toTarget:producer withObject:nil];
    while (!producer->finished) [producer->condition wait];
    [producer->condition unlock];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    BOOL passed = delegate->progressCount == 1 && delegate->lastProgress == 5ULL * 1024 * 1024 * 1024 &&
        delegate->lastTotal == delegate->lastProgress;
    [client reportProgressSent:1 total:1];
    [client invalidate];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    passed = passed && delegate->progressCount == 1;
    printf("%s 20,001 upload updates coalesce into one 64-bit progress callback; cancellation drops pending progress\n",
        passed ? "PASS" : "FAIL");
    [producer->condition release]; [producer release];
    [client release]; [delegate release];
    return passed ? 0 : 1;
}
int main(int argc, char **argv) {
    if (argc < 5) {
        return 2;
    }
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (strcmp(argv[4], "progress") == 0) {
        int result = TestProgressBackpressure();
        [pool drain];
        return result;
    }
    signingGate = [NSCondition new];
    holdSigning = strcmp(argv[4], "cancel-sign") == 0;
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
    BOOL cancellationTest = strcmp(argv[4], "cancel") == 0 || holdSigning;
    if (strcmp(argv[4], "discovery") == 0 || cancellationTest) {
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
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:18];
    if (cancellationTest) {
        while ([transport isRunning] && [limit timeIntervalSinceNow] > 0 &&
               (holdSigning ? !SigningHasEntered() :
                [[transport diagnosticStatus] rangeOfString:@"Waiting for TLS read"].location == NSNotFound)) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        BOOL wasRunning = [transport isRunning];
        NSTimeInterval cancelledAt = [NSDate timeIntervalSinceReferenceDate];
        [transport invalidate];
        BOOL stillRunningDuringSign = [transport isRunning];
        [signingGate lock];
        releaseSigning = YES;
        [signingGate broadcast];
        [signingGate unlock];
        while ([transport isRunning] && [NSDate timeIntervalSinceReferenceDate] - cancelledAt < 2) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        delegate->result = [[NSDictionary alloc] initWithObjectsAndKeys:
            [NSNumber numberWithBool:wasRunning], @"wasRunning",
            [NSNumber numberWithBool:[transport isRunning]], @"running",
            [NSNumber numberWithBool:delegate->done], @"callbackAfterCancel",
            [NSNumber numberWithBool:stillRunningDuringSign], @"runningDuringSign",
            [NSNumber numberWithUnsignedInteger:signingCalls], @"signingCalls",
            [NSNumber numberWithDouble:[NSDate timeIntervalSinceReferenceDate] - cancelledAt], @"cancelSeconds", nil];
        delegate->done = YES;
    }
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
    [signingGate release];
    [pool drain];
    return 0;
}
