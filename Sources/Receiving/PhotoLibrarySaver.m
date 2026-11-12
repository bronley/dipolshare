#import "PhotoLibrarySaver.h"
#import <AssetsLibrary/AssetsLibrary.h>

static const unsigned long long MaximumPhotoAlbumFileSize = 64ULL * 1024ULL * 1024ULL;

@interface PhotoLibrarySaver ()
- (void)savePhotoInBackground:(NSString *)path;
- (void)photoSaveFinished:(NSString *)errorMessage;
- (void)startPhotoAtPath:(NSString *)path;
@end

@implementation PhotoLibrarySaver
@synthesize delegate = _delegate, saving = _saving;

- (BOOL)savePhotoAtPath:(NSString *)path {
    if (_saving) return NO;
    _saving = YES;
    [self startPhotoAtPath:path];
    return YES;
}

- (BOOL)savePhotosAtPaths:(NSArray *)paths {
    if (_saving || [paths count] == 0) return NO;
    _batchPaths = [[NSArray alloc] initWithArray:paths copyItems:YES];
    _failedPaths = [[NSMutableArray alloc] init];
    _completedPhotos = 0;
    _saving = YES;
    [self startPhotoAtPath:[_batchPaths objectAtIndex:0]];
    return YES;
}

- (void)startPhotoAtPath:(NSString *)path {
    NSString *snapshot = [path copy];
    [NSThread detachNewThreadSelector:@selector(savePhotoInBackground:) toTarget:self withObject:snapshot];
    [snapshot release];
}

- (void)savePhotoInBackground:(NSString *)path {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSDictionary *attributes =
        path == nil ? nil : [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    unsigned long long size = [[attributes objectForKey:NSFileSize] unsignedLongLongValue];
    NSString *errorMessage = nil;
    NSData *data = nil;
    if (attributes == nil) {
        errorMessage = @"This file is no longer available.";
    } else if (size > MaximumPhotoAlbumFileSize) {
        errorMessage = @"This photo is too large to save on this device (64 MB limit).";
    } else if (size == 0) {
        errorMessage = @"The photo could not be read.";
    } else {
        data = [[NSData alloc] initWithContentsOfFile:path];
        if ([data length] != size) {
            errorMessage = @"The photo could not be read.";
        }
    }
    if (errorMessage != nil) {
        [self performSelectorOnMainThread:@selector(photoSaveFinished:)
                               withObject:errorMessage
                            waitUntilDone:NO];
    } else {
        if (_photoLibrary == nil) {
            _photoLibrary = [[ALAssetsLibrary alloc] init];
        }
        _photoSaveData = [data retain];
        [_photoLibrary writeImageDataToSavedPhotosAlbum:data
                                               metadata:nil
                                        completionBlock:^(NSURL *assetURL, NSError *error) {
                                            NSString *errorMessage = error == nil && assetURL != nil ? nil
                                                                     : error == nil
                                                                         ? @"The photo could not be saved."
                                                                         : [error localizedDescription];
                                            [self performSelectorOnMainThread:@selector(photoSaveFinished:)
                                                                   withObject:errorMessage
                                                                waitUntilDone:NO];
                                        }];
    }
    [data release];
    [pool drain];
}

- (void)photoSaveFinished:(NSString *)errorMessage {
    [_photoSaveData release];
    _photoSaveData = nil;
    if (_batchPaths != nil) {
        if (errorMessage != nil) {
            [_failedPaths addObject:[_batchPaths objectAtIndex:_completedPhotos]];
            if (_batchError == nil) _batchError = [errorMessage copy];
        }
        _completedPhotos++;
        if ([_delegate respondsToSelector:@selector(photoLibrarySaver:didCompletePhotos:total:)]) {
            [_delegate photoLibrarySaver:self didCompletePhotos:_completedPhotos total:[_batchPaths count]];
        }
        if (_completedPhotos < [_batchPaths count]) {
            [self startPhotoAtPath:[_batchPaths objectAtIndex:_completedPhotos]];
            return;
        }
        NSUInteger savedCount = _completedPhotos - [_failedPaths count];
        NSArray *failedPaths = [_failedPaths autorelease];
        NSString *message = [_batchError autorelease];
        _failedPaths = nil;
        _batchError = nil;
        [_batchPaths release];
        _batchPaths = nil;
        _saving = NO;
        if ([_delegate respondsToSelector:@selector(photoLibrarySaver:didFinishBatchWithSavedCount:failedPaths:errorMessage:)]) {
            [_delegate photoLibrarySaver:self didFinishBatchWithSavedCount:savedCount
                             failedPaths:failedPaths errorMessage:message];
        }
        return;
    }
    _saving = NO;
    [_delegate photoLibrarySaver:self didFinishWithErrorMessage:errorMessage];
}

- (void)dealloc {
    [_batchPaths release];
    [_failedPaths release];
    [_batchError release];
    [_photoLibrary release];
    [_photoSaveData release];
    [super dealloc];
}
@end
