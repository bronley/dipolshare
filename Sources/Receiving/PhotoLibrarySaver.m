#import "PhotoLibrarySaver.h"
#import <AssetsLibrary/AssetsLibrary.h>

static const unsigned long long MaximumPhotoAlbumFileSize = 64ULL * 1024ULL * 1024ULL;

@interface PhotoLibrarySaver ()
- (void)savePhotoInBackground:(NSString *)path;
- (void)photoSaveFinished:(NSString *)errorMessage;
@end

@implementation PhotoLibrarySaver
@synthesize delegate = _delegate, saving = _saving;

- (BOOL)savePhotoAtPath:(NSString *)path {
    if (_saving) return NO;
    _saving = YES;
    NSString *snapshot = [path copy];
    [NSThread detachNewThreadSelector:@selector(savePhotoInBackground:) toTarget:self withObject:snapshot];
    [snapshot release];
    return YES;
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
    _saving = NO;
    [_photoSaveData release];
    _photoSaveData = nil;
    [_delegate photoLibrarySaver:self didFinishWithErrorMessage:errorMessage];
}

- (void)dealloc {
    [_photoLibrary release];
    [_photoSaveData release];
    [super dealloc];
}
@end
