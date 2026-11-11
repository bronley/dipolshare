#import <Foundation/Foundation.h>

typedef enum {
    HTTPResponseInvalid = -1,
    HTTPResponseIncomplete = 0,
    HTTPResponseComplete = 1
} HTTPResponseParseResult;

// End-of-stream requires authenticated TLS close_notify, unless framing already completed.
HTTPResponseParseResult ParseHTTPResponse(NSData *response, BOOL endOfStream,
                                                            NSInteger *status, NSData **body,
                                                            NSString **errorMessage);
