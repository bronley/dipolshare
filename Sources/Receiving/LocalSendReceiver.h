#import <Foundation/Foundation.h>
#import "LocalSendReceiveServer.h"

@class LocalSendReceivedFileStore;

extern NSString *const LocalSendReceiveRequestNotification;
extern NSString *const LocalSendReceiveProgressNotification;
extern NSString *const LocalSendReceivedFilesDidChangeNotification;
extern NSString *const LocalSendReceivePeerDidRegisterNotification;

@interface LocalSendReceiver : NSObject <LocalSendReceiveServerDelegate> {
    NSCondition *_sessionCondition;
    NSMutableDictionary *_currentSession;
    NSMutableSet *_activeUploads;
    NSDictionary *_localDeviceInfo;
    LocalSendReceivedFileStore *_fileStore;
    NSTimeInterval _lastProgressUpdateTime;
    BOOL _isReceivingEnabled;
}

+ (LocalSendReceiver *)sharedReceiver;
- (void)setLocalInfo:(NSDictionary *)info;
- (void)stop;
- (void)checkTimeouts;
- (NSDictionary *)pendingRequest;
- (void)respondToRequest:(NSString *)requestIdentifier accept:(BOOL)accept;
- (void)cancelCurrentTransfer;
- (NSArray *)receivedFiles;
- (NSUInteger)unseenReceivedFileCount;
- (BOOL)markReceivedFilesSeen;
@end
