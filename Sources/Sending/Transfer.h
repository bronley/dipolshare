#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import "HTTPSClient.h"

extern NSString *const TransferDidUpdateNotification;

@interface Transfer : NSObject {
    NSDictionary *_recipientDevice;
    NSData *_clipboardData;
    NSString *_clipboardText;
    NSString *_clipboardFileIdentifier;
    NSString *_contactsFilePath;
    NSString *_contactsFileName;
    NSArray *_photoAssets;
    ALAssetsLibrary *_photoLibrary;
    NSArray *_outgoingFiles;
    NSDictionary *_uploadTokensByFileIdentifier;
    NSString *_uploadSessionIdentifier;
    NSString *_temporaryPhotoFilePath;
    NSUInteger _currentFileIndex;
    volatile BOOL _cancelled;
    NSURLConnection *_httpConnection;
    HTTPSClient *_httpsClient;
    NSMutableData *_responseData;
    NSInteger _responseStatusCode;
    BOOL _isUploadingFiles;
    SecIdentityRef _identity;
    NSString *_identityFingerprint;
}

- (id)initWithDevice:(NSDictionary *)device photoAssets:(NSArray *)assets library:(ALAssetsLibrary *)library;
- (id)initWithDevice:(NSDictionary *)device clipboardText:(NSString *)text;
- (id)initWithDevice:(NSDictionary *)device contactsFileAtPath:(NSString *)path fileName:(NSString *)name;
- (void)start;
- (void)cancel;
@end
