#import "LocalSendHTTPResponseParser.h"
#include <string.h>

static const NSUInteger kLocalSendMaxResponseBody = 1024 * 1024;
static const NSUInteger kLocalSendMaxResponseHeaders = 65536;
static const NSUInteger kLocalSendMaxResponseWire = 2 * 1024 * 1024;

static LocalSendHTTPResponseParseResult LocalSendResponseError(NSString **errorMessage, NSString *message) {
    if (errorMessage != NULL) {
        *errorMessage = message;
    }
    return LocalSendHTTPResponseInvalid;
}

static LocalSendHTTPResponseParseResult LocalSendResponseIncomplete(BOOL endOfStream,
                                                                    NSString **errorMessage) {
    return endOfStream ? LocalSendResponseError(errorMessage, @"Truncated HTTP response.")
                       : LocalSendHTTPResponseIncomplete;
}

static BOOL LocalSendParseHTTPHeaderField(NSString *line, NSString **name, NSString **value) {
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound || colon.location == 0) {
        return NO;
    }
    NSUInteger index;
    for (index = 0; index < [line length]; index++) {
        unichar character = [line characterAtIndex:index];
        if (index < colon.location) {
            BOOL token = (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
                         (character >= '0' && character <= '9') ||
                         (character < 128 && character != 0 && strchr("!#$%&'*+-.^_`|~", character) != NULL);
            if (!token) {
                return NO;
            }
        } else if ((character < 32 && character != '\t') || character == 127) {
            return NO;
        }
    }
    *name = [[line substringToIndex:colon.location] lowercaseString];
    *value = [[line substringFromIndex:colon.location + 1]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return YES;
}

// Parsing preserves incomplete input until the authenticated end of the TLS stream.
static LocalSendHTTPResponseParseResult LocalSendParseResponseHeaders(NSData *response, BOOL endOfStream,
                                                                      NSInteger *status,
                                                                      NSDictionary **responseHeaders,
                                                                      NSUInteger *responseBodyOffset,
                                                                      NSString **errorMessage) {
    NSUInteger length = [response length];
    if (length > kLocalSendMaxResponseWire) {
        return LocalSendResponseError(errorMessage, @"HTTP response is too large.");
    }
    const unsigned char *bytes = [response bytes];
    NSData *separator = [NSData dataWithBytes:"\r\n\r\n" length:4];
    NSUInteger headerStart = 0;
    NSUInteger headerBytes = 0;
    NSUInteger informationalCount = 0;
    NSMutableDictionary *fields = nil;
    NSUInteger bodyOffset = 0;
    while (YES) {
        NSRange end = [response rangeOfData:separator
                                    options:0
                                      range:NSMakeRange(headerStart, length - headerStart)];
        if (end.location == NSNotFound) {
            if (length - headerStart + headerBytes > kLocalSendMaxResponseHeaders) {
                return LocalSendResponseError(errorMessage, @"HTTP response headers are too large.");
            }
            return LocalSendResponseIncomplete(endOfStream, errorMessage);
        }
        headerBytes += NSMaxRange(end) - headerStart;
        if (headerBytes > kLocalSendMaxResponseHeaders) {
            return LocalSendResponseError(errorMessage, @"HTTP response headers are too large.");
        }
        NSString *headers = [[[NSString alloc] initWithBytes:bytes + headerStart
                                                      length:end.location - headerStart
                                                    encoding:NSISOLatin1StringEncoding] autorelease];
        NSArray *lines = [headers componentsSeparatedByString:@"\r\n"];
        NSString *first = [lines count] > 0 ? [lines objectAtIndex:0] : nil;
        if ([first length] < 12 || !([first hasPrefix:@"HTTP/1.1 "] || [first hasPrefix:@"HTTP/1.0 "]) ||
            ([first length] > 12 && [first characterAtIndex:12] != ' ')) {
            return LocalSendResponseError(errorMessage, @"Malformed HTTP response status line.");
        }
        NSUInteger index;
        NSInteger code = 0;
        for (index = 9; index < 12; index++) {
            unichar character = [first characterAtIndex:index];
            if (character < '0' || character > '9') {
                return LocalSendResponseError(errorMessage, @"Malformed HTTP response status code.");
            }
            code = code * 10 + character - '0';
        }
        if (code < 100 || code > 599) {
            return LocalSendResponseError(errorMessage, @"Invalid HTTP response status code.");
        }
        for (index = 12; index < [first length]; index++) {
            unichar character = [first characterAtIndex:index];
            if ((character < 32 && character != '\t') || character == 127) {
                return LocalSendResponseError(errorMessage, @"Malformed HTTP response status line.");
            }
        }
        fields = [NSMutableDictionary dictionary];
        for (index = 1; index < [lines count]; index++) {
            NSString *name = nil, *value = nil;
            if (!LocalSendParseHTTPHeaderField([lines objectAtIndex:index], &name, &value)) {
                return LocalSendResponseError(errorMessage, @"Malformed HTTP response header.");
            }
            if ([fields objectForKey:name] != nil &&
                ([name isEqualToString:@"content-length"] || [name isEqualToString:@"transfer-encoding"])) {
                return LocalSendResponseError(errorMessage, @"Ambiguous duplicate HTTP framing header.");
            }
            [fields setObject:value forKey:name];
        }
        bodyOffset = NSMaxRange(end);
        if (code >= 200) {
            *status = code;
            break;
        }
        if (code == 101 || ++informationalCount > 8 || [fields objectForKey:@"content-length"] != nil ||
            [fields objectForKey:@"transfer-encoding"] != nil) {
            return LocalSendResponseError(errorMessage, @"Unsupported informational HTTP response.");
        }
        headerStart = bodyOffset;
    }
    *responseHeaders = fields;
    *responseBodyOffset = bodyOffset;
    return LocalSendHTTPResponseComplete;
}

static LocalSendHTTPResponseParseResult LocalSendParseChunkedResponseBody(NSData *response,
                                                                          NSUInteger bodyOffset,
                                                                          BOOL endOfStream, NSData **body,
                                                                          NSString **errorMessage) {
    NSUInteger length = [response length];
    const unsigned char *bytes = [response bytes];
    NSUInteger offset = bodyOffset;
    NSUInteger decodedLength = 0;
    NSUInteger framingBytes = 0;
    NSMutableData *decoded = body != NULL ? [NSMutableData data] : nil;
    while (YES) {
        NSUInteger lineEnd = offset;
        while (lineEnd + 1 < length && !(bytes[lineEnd] == '\r' && bytes[lineEnd + 1] == '\n')) {
            lineEnd++;
        }
        if (lineEnd + 1 >= length) {
            if (length - offset > 8192) {
                return LocalSendResponseError(errorMessage, @"HTTP chunk-size line is too large.");
            }
            return LocalSendResponseIncomplete(endOfStream, errorMessage);
        }
        framingBytes += lineEnd - offset + 2;
        if (lineEnd - offset > 8192 || framingBytes > kLocalSendMaxResponseHeaders) {
            return LocalSendResponseError(errorMessage, @"HTTP chunk framing is too large.");
        }
        NSUInteger chunkLength = 0, digits = 0, cursor = offset;
        for (; cursor < lineEnd && bytes[cursor] != ';'; cursor++) {
            unsigned char character = bytes[cursor];
            unsigned int digit;
            if (character >= '0' && character <= '9') {
                digit = character - '0';
            } else if (character >= 'a' && character <= 'f') {
                digit = character - 'a' + 10;
            } else if (character >= 'A' && character <= 'F') {
                digit = character - 'A' + 10;
            } else {
                return LocalSendResponseError(errorMessage, @"Malformed HTTP chunk size.");
            }
            if (chunkLength > (kLocalSendMaxResponseBody - digit) / 16) {
                return LocalSendResponseError(errorMessage, @"HTTP response body is too large.");
            }
            chunkLength = chunkLength * 16 + digit;
            digits++;
        }
        if (digits == 0) {
            return LocalSendResponseError(errorMessage, @"Missing HTTP chunk size.");
        }
        for (; cursor < lineEnd; cursor++) {
            if (bytes[cursor] < 32 || bytes[cursor] == 127) {
                return LocalSendResponseError(errorMessage, @"Malformed HTTP chunk extension.");
            }
        }
        offset = lineEnd + 2;
        if (chunkLength == 0) {
            NSUInteger trailerStart = offset;
            while (YES) {
                lineEnd = offset;
                while (lineEnd + 1 < length && !(bytes[lineEnd] == '\r' && bytes[lineEnd + 1] == '\n')) {
                    lineEnd++;
                }
                if (lineEnd + 1 >= length) {
                    if (length - trailerStart + framingBytes > kLocalSendMaxResponseHeaders) {
                        return LocalSendResponseError(errorMessage, @"HTTP trailers are too large.");
                    }
                    return LocalSendResponseIncomplete(endOfStream, errorMessage);
                }
                if (lineEnd + 2 - trailerStart + framingBytes > kLocalSendMaxResponseHeaders) {
                    return LocalSendResponseError(errorMessage, @"HTTP trailers are too large.");
                }
                if (lineEnd == offset) {
                    if (lineEnd + 2 != length) {
                        return LocalSendResponseError(errorMessage, @"Unexpected bytes after HTTP response.");
                    }
                    if (body != NULL) {
                        *body = decoded;
                    }
                    return LocalSendHTTPResponseComplete;
                }
                NSString *line = [[[NSString alloc] initWithBytes:bytes + offset
                                                           length:lineEnd - offset
                                                         encoding:NSISOLatin1StringEncoding] autorelease];
                NSString *name = nil, *value = nil;
                if (!LocalSendParseHTTPHeaderField(line, &name, &value) ||
                    [name isEqualToString:@"content-length"] || [name isEqualToString:@"transfer-encoding"] ||
                    [name isEqualToString:@"trailer"]) {
                    return LocalSendResponseError(errorMessage, @"Malformed HTTP response trailer.");
                }
                offset = lineEnd + 2;
            }
        }
        if (chunkLength > kLocalSendMaxResponseBody - decodedLength) {
            return LocalSendResponseError(errorMessage, @"HTTP response body is too large.");
        }
        if (chunkLength + 2 > length - offset) {
            return LocalSendResponseIncomplete(endOfStream, errorMessage);
        }
        if (bytes[offset + chunkLength] != '\r' || bytes[offset + chunkLength + 1] != '\n') {
            return LocalSendResponseError(errorMessage, @"Malformed HTTP chunk terminator.");
        }
        [decoded appendBytes:bytes + offset length:chunkLength];
        decodedLength += chunkLength;
        offset += chunkLength + 2;
    }
}

LocalSendHTTPResponseParseResult LocalSendParseHTTPResponse(NSData *response, BOOL endOfStream,
                                                            NSInteger *status, NSData **body,
                                                            NSString **errorMessage) {
    NSDictionary *fields = nil;
    NSUInteger bodyOffset = 0;
    LocalSendHTTPResponseParseResult headerResult =
        LocalSendParseResponseHeaders(response, endOfStream, status, &fields, &bodyOffset, errorMessage);
    if (headerResult != LocalSendHTTPResponseComplete) {
        return headerResult;
    }
    NSUInteger length = [response length];
    NSString *contentLength = [fields objectForKey:@"content-length"];
    NSString *transferEncoding = [fields objectForKey:@"transfer-encoding"];
    if (contentLength != nil && transferEncoding != nil) {
        return LocalSendResponseError(errorMessage, @"Ambiguous HTTP response framing.");
    }
    if (*status == 204 || *status == 304) {
        if (bodyOffset != length || transferEncoding != nil ||
            (*status == 204 && contentLength != nil && ![contentLength isEqualToString:@"0"])) {
            return LocalSendResponseError(errorMessage, @"Unexpected body in an empty HTTP response.");
        }
        if (body != NULL) {
            *body = [NSData data];
        }
        return LocalSendHTTPResponseComplete;
    }
    if (transferEncoding != nil) {
        if (![[transferEncoding lowercaseString] isEqualToString:@"chunked"]) {
            return LocalSendResponseError(errorMessage, @"Unsupported HTTP response transfer encoding.");
        }
        return LocalSendParseChunkedResponseBody(response, bodyOffset, endOfStream, body, errorMessage);
    }
    NSUInteger rawLength = length - bodyOffset;
    if (contentLength != nil) {
        if ([contentLength length] == 0) {
            return LocalSendResponseError(errorMessage, @"Missing HTTP content length.");
        }
        NSUInteger expected = 0, index;
        for (index = 0; index < [contentLength length]; index++) {
            unichar character = [contentLength characterAtIndex:index];
            if (character < '0' || character > '9') {
                return LocalSendResponseError(errorMessage, @"Malformed HTTP content length.");
            }
            if (expected > (kLocalSendMaxResponseBody - (character - '0')) / 10) {
                return LocalSendResponseError(errorMessage, @"HTTP response body is too large.");
            }
            expected = expected * 10 + character - '0';
        }
        if (rawLength < expected) {
            return LocalSendResponseIncomplete(endOfStream, errorMessage);
        }
        if (rawLength > expected) {
            return LocalSendResponseError(errorMessage, @"Unexpected bytes after HTTP response.");
        }
    } else {
        if (rawLength > kLocalSendMaxResponseBody) {
            return LocalSendResponseError(errorMessage, @"HTTP response body is too large.");
        }
        if (!endOfStream) {
            return LocalSendHTTPResponseIncomplete;
        }
    }
    if (body != NULL) {
        *body = [response subdataWithRange:NSMakeRange(bodyOffset, rawLength)];
    }
    return LocalSendHTTPResponseComplete;
}
