#import <Foundation/Foundation.h>

typedef enum {
    LocalSendHTTPResponseInvalid = -1,
    LocalSendHTTPResponseIncomplete = 0,
    LocalSendHTTPResponseComplete = 1
} LocalSendHTTPResponseParseResult;

// End-of-stream requires authenticated TLS close_notify, unless framing already completed.
LocalSendHTTPResponseParseResult LocalSendParseHTTPResponse(NSData *response, BOOL endOfStream,
                                                            NSInteger *status, NSData **body,
                                                            NSString **errorMessage);
