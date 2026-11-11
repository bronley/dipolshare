#import "Transfer.h"

static inline NSString *NewFileIdentifier(void) {
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    NSString *identifier = (NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    return identifier;
}

// Internal declarations shared by the implementation files.
@interface Transfer ()
- (id)initWithDevice:(NSDictionary *)device;
- (BOOL)loadIdentity;
- (void)removeContactsFile;
- (void)postUploadProgressWithBytesSent:(unsigned long long)bytesSent
                             totalBytes:(unsigned long long)totalBytes;
- (void)postStatus:(NSString *)message;
- (void)postStatus:(NSString *)message isError:(BOOL)isError isActive:(BOOL)isActive;
- (void)completeWithMessage:(NSString *)message;
- (void)failWithMessage:(NSString *)message;
- (void)sendCancellationRequest;
@end

@interface Transfer (Files)
- (NSDictionary *)outgoingFileForPhoto:(ALAsset *)asset;
- (NSDictionary *)outgoingFileForClipboard;
- (BOOL)prepareOutgoingFiles;
@end

@interface Transfer (PhotoExport)
- (void)preparePhotoFile:(NSDictionary *)file;
- (void)photoFilePrepared:(NSDictionary *)result;
- (void)removeTemporaryPhotoFile;
@end

@interface Transfer (Transport) <NSURLConnectionDelegate, HTTPSClientDelegate>
- (void)beginRequestToPath:(NSString *)path
                      body:(NSData *)body
                  bodyFile:(NSString *)filePath
               contentType:(NSString *)contentType;
- (void)beginHTTPRequestToPath:(NSString *)path
                          body:(NSData *)body
                      bodyFile:(NSString *)filePath
                   contentType:(NSString *)contentType;
- (NSURLRequest *)connection:(NSURLConnection *)connection
             willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)response;
- (void)httpsClient:(HTTPSClient *)client
    didCompleteWithStatus:(NSInteger)status
                     body:(NSData *)body;
- (void)httpsClient:(HTTPSClient *)client didFailWithMessage:(NSString *)message;
- (void)httpsClient:(HTTPSClient *)client
    didSendBodyBytes:(unsigned long long)sent
          totalBytes:(unsigned long long)total;
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response;
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data;
- (void)connection:(NSURLConnection *)connection
              didSendBodyData:(NSInteger)bytesWritten
            totalBytesWritten:(NSInteger)totalBytesWritten
    totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite;
- (void)connectionDidFinishLoading:(NSURLConnection *)connection;
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error;
- (void)finishHTTPConnection:(NSURLConnection *)connection;
@end

@interface Transfer (Protocol)
- (NSData *)prepareUploadRequestBody;
- (void)handleResponseData:(NSData *)data statusCode:(NSInteger)statusCode;
- (void)handleAcceptanceData:(NSData *)data statusCode:(NSInteger)statusCode;
- (void)handleUploadStatusCode:(NSInteger)statusCode;
- (NSString *)uploadPathForFile:(NSDictionary *)file;
- (void)uploadNextFile;
@end
