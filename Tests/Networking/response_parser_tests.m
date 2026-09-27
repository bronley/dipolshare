#import <Foundation/Foundation.h>
#include <string.h>
#import "LocalSendHTTPResponseParser.h"
#import "LocalSendCertificateFingerprint.h"
static int checks = 0, failed = 0;
static void Check(BOOL pass, NSString *name) {
    checks++;
    if (!pass) {
        failed++;
    }
    printf("%s %s\n", pass ? "PASS" : "FAIL", [name UTF8String]);
}
static void Response(NSString *name, NSString *wire, BOOL eof, int expected, NSString *expectedBody) {
    NSInteger status = 0;
    NSData *body = nil;
    NSString *error = nil;
    int result = LocalSendParseHTTPResponse([wire dataUsingEncoding:NSISOLatin1StringEncoding], eof, &status,
                                            &body, &error);
    BOOL pass = result == expected;
    if (expected > 0 && expectedBody != nil) {
        pass = pass && [body isEqualToData:[expectedBody dataUsingEncoding:NSUTF8StringEncoding]];
    }
    if (expected < 0) {
        pass = pass && [error length] > 0;
    }
    Check(pass, name);
    if (!pass) {
        printf("  result=%d status=%ld error=%s\n", result, (long)status, [error UTF8String]);
    }
}
static void Fragmented(NSString *name, NSString *wire) {
    NSData *data = [wire dataUsingEncoding:NSUTF8StringEncoding];
    BOOL pass = YES;
    for (NSUInteger i = 0; i < [data length]; i++) {
        NSInteger status = 0;
        NSString *error = nil;
        if (LocalSendParseHTTPResponse([data subdataWithRange:NSMakeRange(0, i)], NO, &status, NULL,
                                       &error) != 0) {
            pass = NO;
        }
        if (LocalSendParseHTTPResponse([data subdataWithRange:NSMakeRange(0, i)], YES, &status, NULL,
                                       &error) != -1) {
            pass = NO;
        }
    }
    Check(pass, name);
}
int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *fixed = @"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    NSString *chunked = @"HTTP/1.1 200 OK\r\nTransfer-Encoding: "
                        @"chunked\r\n\r\n3;test=1\r\nabc\r\n2\r\nde\r\n0\r\nX-Info: okay\r\n\r\n";
    Response(@"Content-Length completes without TLS EOF", fixed, NO, 1, @"hello");
    Response(@"Chunked completes with trailers without TLS EOF", chunked, NO, 1, @"abcde");
    Fragmented(@"Every fragmented fixed-body prefix waits and rejects EOF", fixed);
    Fragmented(@"Every fragmented chunked prefix waits and rejects EOF", chunked);
    NSString *info = [@"HTTP/1.1 100 Continue\r\n\r\n" stringByAppendingString:fixed];
    Response(@"Informational response precedes final response", info, NO, 1, @"hello");
    Fragmented(@"Fragmented informational plus final response", info);
    Response(@"Connection-close framing waits for authenticated EOF", @"HTTP/1.1 200 OK\r\n\r\nhello", NO, 0,
             nil);
    Response(@"Connection-close framing completes on authenticated EOF", @"HTTP/1.1 200 OK\r\n\r\nhello", YES,
             1, @"hello");
    Response(@"Empty upload response completes immediately", @"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
             NO, 1, @"");
    Response(@"No-content response completes immediately", @"HTTP/1.1 204 No Content\r\n\r\n", NO, 1, @"");
    Response(@"Rejection body preserved", @"HTTP/1.1 403 Forbidden\r\nContent-Length: 8\r\n\r\ndeclined", NO,
             1, @"declined");
    Response(@"Mixed-case chunk header", @"HTTP/1.1 200 OK\r\nTrAnSfEr-EnCoDiNg: ChUnKeD\r\n\r\n0\r\n\r\n",
             NO, 1, @"");
    Response(@"Missing zero-chunk trailer terminator waits",
             @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n", NO, 0, nil);
    Response(@"Missing zero-chunk trailer terminator rejects EOF",
             @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n", YES, -1, nil);
    NSArray *invalid = [NSArray
        arrayWithObjects:
            @"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx",
            @"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            @"HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
            @"HTTP/1.1 200 OK\r\nContent-Length: 2garbage\r\n\r\nab",
            @"HTTP/1.1 200 OK\r\nContent-Length: 18446744073709551616\r\n\r\n",
            @"HTTP/1.1 200 OK\r\nTransfer-Encoding: xchunked\r\n\r\n0\r\n\r\n",
            @"HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n",
            @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n+1\r\nx\r\n0\r\n\r\n",
            @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1garbage\r\nx\r\n0\r\n\r\n",
            @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n100001\r\n",
            @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx!!",
            @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 0\r\n\r\n",
            @"HTTP/1.1 200 OK\r\nBad Header: bad\r\n\r\n", @"HTTP/1.1 200 OK\r\nContent-Length : 0\r\n\r\n",
            @"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nextra",
            @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nextra",
            @"HTTP/1.1 204 No Content\r\nContent-Length: 1\r\n\r\nx",
            @"HTTP/1.1 101 Switching Protocols\r\n\r\n",
            @"HTTP/1.1 100 Continue\r\nContent-Length: 0\r\n\r\n", @"HTTP/1.1 600 Invalid\r\n\r\n",
            @"HTTP/1.1 20 Bad\r\n\r\n", @"HTTP/1.1 200Bad\r\n\r\n", nil];
    NSUInteger i = 0;
    for (NSString *wire in invalid) {
        Response([NSString stringWithFormat:@"Malformed/ambiguous framing rejected %lu", (unsigned long)++i],
                 wire, YES, -1, nil);
    }
    NSString *large = [@"a" stringByPaddingToLength:1048577 withString:@"a" startingAtIndex:0];
    Response(@"Close-delimited body cap", [@"HTTP/1.1 200 OK\r\n\r\n" stringByAppendingString:large], NO, -1,
             nil);
    Response(@"Content-Length body cap checked before receiving",
             @"HTTP/1.1 200 OK\r\nContent-Length: 1048577\r\n\r\n", NO, -1, nil);
    Response(@"Header cap checked before terminator",
             [@"HTTP/1.1 200 OK\r\nX: " stringByAppendingString:large], NO, -1, nil);
    NSString *fp = [@"A" stringByPaddingToLength:64 withString:@"A" startingAtIndex:0];
    NSString *other = [@"B" stringByPaddingToLength:64 withString:@"B" startingAtIndex:0];
    Check(LocalSendPeerFingerprintMatches(fp, fp, NO), @"Transfer matching pin accepted");
    Check(!LocalSendPeerFingerprintMatches(other, fp, NO), @"Transfer wrong pin rejected");
    Check(!LocalSendPeerFingerprintMatches(nil, fp, NO), @"Transfer missing pin rejected");
    Check(LocalSendPeerFingerprintMatches(nil, fp, YES), @"Unknown discovery learns pin");
    Check(!LocalSendPeerFingerprintMatches(other, fp, YES), @"Advertised discovery pin cannot be bypassed");
    Check(!LocalSendPeerFingerprintMatches(@"invalid", fp, YES), @"Invalid advertised pin rejected");
    Check(!LocalSendPeerFingerprintMatches(nil, @"invalid", YES),
          @"Discovery requires valid actual fingerprint");
    Check(LocalSendPeerFingerprintMatches([fp lowercaseString], fp, NO), @"Fingerprint case normalized");
    printf("%d/%d tests passed\n", checks - failed, checks);
    [pool drain];
    return failed ? 1 : 0;
}
