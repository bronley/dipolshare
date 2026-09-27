#import <Foundation/Foundation.h>

@interface LocalSendReceivedFileStore : NSObject {
    NSString *_receivedFilesPath;
    NSString *_stagingPath;
    NSString *_indexPath;
    NSMutableArray *_receivedFiles;
}
- (BOOL)hasSpaceForByteCount:(unsigned long long)byteCount;
- (NSString *)stagingPathForIdentifier:(NSString *)identifier;
- (NSString *)destinationPathForIdentifier:(NSString *)identifier fileName:(NSString *)fileName;
- (void)removeStagedFileAtPath:(NSString *)path;
- (BOOL)saveStagedFileAtPath:(NSString *)stagingPath
             destinationPath:(NSString *)destinationPath
                    fileName:(NSString *)fileName
                    fileType:(NSString *)fileType
                   byteCount:(unsigned long long)byteCount
                errorMessage:(NSString **)errorMessage;
- (NSArray *)receivedFiles;
- (NSUInteger)unseenFileCount;
- (BOOL)markAllFilesSeen;
@end
