#import <Foundation/Foundation.h>

@class ContactBackup;
@protocol ContactBackupDelegate <NSObject>
- (void)contactBackupDidFinish:(ContactBackup *)backup;
@end

@interface ContactBackup : NSObject {
    id<ContactBackupDelegate> _delegate;
    BOOL _cancelled;
    NSString *_filePath;
    NSString *_fileName;
    NSString *_errorMessage;
    NSUInteger _contactCount;
}
@property(nonatomic, assign) id<ContactBackupDelegate> delegate;
@property(nonatomic, readonly) NSString *fileName;
@property(nonatomic, readonly) NSString *errorMessage;
@property(nonatomic, readonly) NSUInteger contactCount;
- (void)start;
- (void)cancel;
// Transfers ownership of the temporary file to the caller, who must delete it.
- (NSString *)takeFilePath;
@end
