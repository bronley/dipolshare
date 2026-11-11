#import "Transfer+Private.h"
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

@implementation Transfer (PhotoExport)

- (void)preparePhotoFile:(NSDictionary *)file {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    ALAssetRepresentation *representation = [[file objectForKey:@"asset"] defaultRepresentation];
    unsigned long long expectedByteCount = [[file objectForKey:@"size"] unsignedLongLongValue];
    NSString *uniqueIdentifier = NewFileIdentifier();
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"LocalSend-%@.part", uniqueIdentifier]];
    [uniqueIdentifier release];
    int fileDescriptor = open([path fileSystemRepresentation], O_CREAT | O_EXCL | O_WRONLY, 0600);
    BOOL copySucceeded = representation != nil && expectedByteCount > 0 &&
                         expectedByteCount == [representation size] && fileDescriptor >= 0;
    unsigned char buffer[32768];
    unsigned long long bytesCopied = 0;
    while (copySucceeded && bytesCopied < expectedByteCount) {
        if (_cancelled) {
            copySucceeded = NO;
            break;
        }
        NSUInteger bytesRequested =
            (NSUInteger)MIN((unsigned long long)sizeof(buffer), expectedByteCount - bytesCopied);
        NSAutoreleasePool *chunkPool = [[NSAutoreleasePool alloc] init];
        NSError *error = nil;
        NSUInteger bytesRead = [representation getBytes:buffer
                                             fromOffset:(long long)bytesCopied
                                                 length:bytesRequested
                                                  error:&error];
        if (bytesRead == 0 || bytesRead > bytesRequested || error != nil) {
            copySucceeded = NO;
        }
        NSUInteger bytesWritten = 0;
        while (copySucceeded && bytesWritten < bytesRead) {
            ssize_t result = write(fileDescriptor, buffer + bytesWritten, bytesRead - bytesWritten);
            if (result < 0 && errno == EINTR) {
                continue;
            }
            if (result <= 0) {
                copySucceeded = NO;
                break;
            }
            bytesWritten += (NSUInteger)result;
        }
        if (copySucceeded) {
            bytesCopied += bytesRead;
        }
        [chunkPool drain];
    }
    if (fileDescriptor >= 0 && close(fileDescriptor) != 0) {
        copySucceeded = NO;
    }
    copySucceeded = copySucceeded && bytesCopied == expectedByteCount;
    if (!copySucceeded) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }
    NSDictionary *result =
        [NSDictionary dictionaryWithObjectsAndKeys:file, @"file", copySucceeded ? path : @"", @"path", nil];
    [self performSelectorOnMainThread:@selector(photoFilePrepared:) withObject:result waitUntilDone:NO];
    [pool drain];
}

- (void)photoFilePrepared:(NSDictionary *)result {
    NSString *path = [result objectForKey:@"path"];
    NSDictionary *file = [result objectForKey:@"file"];
    if (_cancelled || !_isUploadingFiles || _currentFileIndex >= [_outgoingFiles count] ||
        [_outgoingFiles objectAtIndex:_currentFileIndex] != file) {
        if ([path length] > 0) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        }
        return;
    }
    if ([path length] == 0) {
        [self
            failWithMessage:@"Transfer failed: could not read a selected photo or video or save its temporary copy."];
        return;
    }
    _temporaryPhotoFilePath = [path copy];
    [self beginRequestToPath:[self uploadPathForFile:file]
                        body:nil
                    bodyFile:path
                 contentType:@"application/octet-stream"];
}

- (void)removeTemporaryPhotoFile {
    if (_temporaryPhotoFilePath == nil) {
        return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:_temporaryPhotoFilePath error:NULL];
    [_temporaryPhotoFilePath release];
    _temporaryPhotoFilePath = nil;
}
@end
