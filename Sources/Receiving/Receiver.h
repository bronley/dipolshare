#import <Foundation/Foundation.h>
#import "ReceiveServer.h"

@class ReceivedFileStore;

extern NSString *const ReceiveRequestNotification;
extern NSString *const ReceiveProgressNotification;
extern NSString *const ReceivedFilesDidChangeNotification;
extern NSString *const ReceivePeerDidRegisterNotification;

@interface Receiver : NSObject <ReceiveServerDelegate> {
    NSCondition *_sessionCondition;
    NSMutableDictionary *_currentSession;
    NSMutableSet *_activeUploads;
    NSDictionary *_localDeviceInfo;
    ReceivedFileStore *_fileStore;
    NSTimeInterval _lastProgressUpdateTime;
    BOOL _isReceivingEnabled;
}

+ (Receiver *)sharedReceiver;
- (void)setLocalInfo:(NSDictionary *)info;
- (void)stop;
- (void)checkTimeouts;
- (NSDictionary *)pendingRequest;
- (void)respondToRequest:(NSString *)requestIdentifier accept:(BOOL)accept;
- (void)cancelCurrentTransfer;
- (NSArray *)receivedFiles;
- (NSArray *)deleteReceivedFilesAtPaths:(NSArray *)paths errorMessage:(NSString **)errorMessage;
- (NSUInteger)unseenReceivedFileCount;
- (BOOL)markReceivedFilesSeen;
@end
