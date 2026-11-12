#import "ReceivedFileStore.h"
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

static const unsigned long long ReservedFreeStorage = 16ULL * 1024ULL * 1024ULL;

@interface ReceivedFileStore ()
- (void)loadReceivedFilesIndex;
@end

@implementation ReceivedFileStore

- (id)init {
    self = [super init];
    if (self) {
        NSString *documentsPath =
            [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
        NSString *cachesPath =
            [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
        NSString *supportPath = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                                     NSUserDomainMask, YES) objectAtIndex:0];
        _receivedFilesPath = [[documentsPath stringByAppendingPathComponent:@"Received"] copy];
        _stagingPath = [[cachesPath stringByAppendingPathComponent:@"LocalSendIncoming"] copy];
        _indexPath = [[supportPath stringByAppendingPathComponent:@"LocalSendReceived.plist"] copy];
        _receivedFiles = [[NSMutableArray alloc] init];

        NSFileManager *fileManager = [NSFileManager defaultManager];
        [fileManager createDirectoryAtPath:_receivedFilesPath
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:NULL];
        [fileManager createDirectoryAtPath:supportPath
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:NULL];
        // Unfinished uploads are confined to this app-owned staging directory.
        [fileManager removeItemAtPath:_stagingPath error:NULL];
        [fileManager createDirectoryAtPath:_stagingPath
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:NULL];
        [self loadReceivedFilesIndex];
    }
    return self;
}

- (void)loadReceivedFilesIndex {
    NSArray *savedFiles = [NSArray arrayWithContentsOfFile:_indexPath];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (id entry in savedFiles) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *relativePath = [entry objectForKey:@"relativePath"];
        if (![relativePath isKindOfClass:[NSString class]] || [relativePath length] == 0 ||
            [relativePath length] > 512 || [relativePath isAbsolutePath] ||
            [[relativePath pathComponents] containsObject:@".."]) {
            continue;
        }
        NSString *path = [_receivedFilesPath stringByAppendingPathComponent:relativePath];
        if ([fileManager fileExistsAtPath:path]) {
            [_receivedFiles addObject:entry];
        }
    }
}

- (BOOL)hasSpaceForByteCount:(unsigned long long)byteCount {
    NSDictionary *attributes =
        [[NSFileManager defaultManager] attributesOfFileSystemForPath:_receivedFilesPath error:NULL];
    unsigned long long freeByteCount = [[attributes objectForKey:NSFileSystemFreeSize] unsignedLongLongValue];
    return freeByteCount > ReservedFreeStorage &&
           byteCount <= freeByteCount - ReservedFreeStorage;
}

- (NSString *)stagingPathForIdentifier:(NSString *)identifier {
    return [_stagingPath stringByAppendingPathComponent:[identifier stringByAppendingString:@".part"]];
}

- (NSString *)destinationPathForIdentifier:(NSString *)identifier fileName:(NSString *)fileName {
    return [[_receivedFilesPath stringByAppendingPathComponent:identifier]
        stringByAppendingPathComponent:fileName];
}

- (void)removeStagedFileAtPath:(NSString *)path {
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

- (BOOL)saveStagedFileAtPath:(NSString *)stagingPath
             destinationPath:(NSString *)destinationPath
                    fileName:(NSString *)fileName
                    fileType:(NSString *)fileType
                   byteCount:(unsigned long long)byteCount
                errorMessage:(NSString **)errorMessage {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *folderPath = [destinationPath stringByDeletingLastPathComponent];
    BOOL saved = [fileManager createDirectoryAtPath:folderPath
                        withIntermediateDirectories:NO
                                         attributes:nil
                                              error:NULL] &&
                 [fileManager moveItemAtPath:stagingPath toPath:destinationPath error:NULL];
    if (!saved) {
        [fileManager removeItemAtPath:folderPath error:NULL];
        if (errorMessage != NULL) {
            *errorMessage = @"Receiving failed: could not save the file.";
        }
        return NO;
    }

    NSString *relativePath = [destinationPath substringFromIndex:[_receivedFilesPath length] + 1];
    NSDictionary *entry =
        [NSDictionary dictionaryWithObjectsAndKeys:relativePath, @"relativePath", fileName, @"name", fileType,
                                                   @"type", [NSNumber numberWithUnsignedLongLong:byteCount],
                                                   @"size", [NSDate date], @"date",
                                                   [NSNumber numberWithBool:YES], @"unseen", nil];
    [_receivedFiles addObject:entry];
    if (![_receivedFiles writeToFile:_indexPath atomically:YES]) {
        [_receivedFiles removeLastObject];
        [fileManager removeItemAtPath:folderPath error:NULL];
        if (errorMessage != NULL) {
            *errorMessage = @"Receiving failed: could not update the received-files list.";
        }
        return NO;
    }
    return YES;
}

- (NSArray *)receivedFiles {
    NSMutableArray *files = [NSMutableArray array];
    for (NSDictionary *entry in [_receivedFiles reverseObjectEnumerator]) {
        NSMutableDictionary *file = [[entry mutableCopy] autorelease];
        NSString *path =
            [_receivedFilesPath stringByAppendingPathComponent:[entry objectForKey:@"relativePath"]];
        [file setObject:path forKey:@"path"];
        [files addObject:file];
    }
    return [NSArray arrayWithArray:files];
}

- (NSArray *)deleteFilesAtPaths:(NSArray *)paths errorMessage:(NSString **)errorMessage {
    if (errorMessage != NULL) *errorMessage = nil;
    NSMutableArray *failed = [NSMutableArray array];
    NSMutableSet *requested = [NSMutableSet setWithArray:paths];
    NSMutableArray *remaining = [NSMutableArray arrayWithArray:_receivedFiles];
    BOOL changed = NO;
    struct stat rootInfo;
    BOOL validRoot = lstat([_receivedFilesPath fileSystemRepresentation], &rootInfo) == 0 && S_ISDIR(rootInfo.st_mode);
    for (NSDictionary *entry in _receivedFiles) {
        NSString *relative = [entry objectForKey:@"relativePath"];
        NSString *path = [_receivedFilesPath stringByAppendingPathComponent:relative];
        if (![requested containsObject:path]) continue;
        [requested removeObject:path];
        NSArray *parts = [relative pathComponents];
        NSString *parent = [path stringByDeletingLastPathComponent];
        struct stat parentInfo, fileInfo;
        int parentResult = lstat([parent fileSystemRepresentation], &parentInfo);
        BOOL validParent = parentResult == 0 ? S_ISDIR(parentInfo.st_mode) : errno == ENOENT;
        BOOL safe = validRoot && validParent && [parts count] == 2 &&
            ![parts containsObject:@".."] && ![parts containsObject:@"."] && ![relative isAbsolutePath];
        BOOL removed = NO;
        if (safe) {
            int result = lstat([path fileSystemRepresentation], &fileInfo);
            if (result != 0) removed = errno == ENOENT;
            else if (S_ISREG(fileInfo.st_mode) || S_ISLNK(fileInfo.st_mode)) {
                removed = unlink([path fileSystemRepresentation]) == 0 || errno == ENOENT;
            }
        }
        if (!removed) {
            [failed addObject:path];
            continue;
        }
        [remaining removeObjectIdenticalTo:entry];
        changed = YES;
        rmdir([parent fileSystemRepresentation]);
    }
    [failed addObjectsFromArray:[requested allObjects]];
    if (changed) {
        [_receivedFiles setArray:remaining];
        if (![_receivedFiles writeToFile:_indexPath atomically:YES] && errorMessage != NULL) {
            *errorMessage = @"The files were deleted, but the received-files index could not be updated.";
        }
    }
    if ([failed count] > 0 && errorMessage != NULL) {
        *errorMessage = @"Some files could not be deleted. They remain in Received.";
    }
    return [NSArray arrayWithArray:failed];
}

- (NSUInteger)unseenFileCount {
    NSUInteger count = 0;
    for (NSDictionary *entry in _receivedFiles) {
        if ([[entry objectForKey:@"unseen"] boolValue]) {
            count++;
        }
    }
    return count;
}

- (BOOL)markAllFilesSeen {
    if ([self unseenFileCount] == 0) {
        return YES;
    }
    NSMutableArray *updatedFiles = [NSMutableArray arrayWithCapacity:[_receivedFiles count]];
    for (NSDictionary *entry in _receivedFiles) {
        if ([[entry objectForKey:@"unseen"] boolValue]) {
            NSMutableDictionary *seenEntry = [[entry mutableCopy] autorelease];
            [seenEntry removeObjectForKey:@"unseen"];
            [updatedFiles addObject:seenEntry];
        } else {
            [updatedFiles addObject:entry];
        }
    }
    if (![updatedFiles writeToFile:_indexPath atomically:YES]) {
        return NO;
    }
    [_receivedFiles setArray:updatedFiles];
    return YES;
}

- (void)dealloc {
    [_receivedFilesPath release];
    [_stagingPath release];
    [_indexPath release];
    [_receivedFiles release];
    [super dealloc];
}
@end
