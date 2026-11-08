#import <Foundation/Foundation.h>

@class ALAssetsLibrary;
@class PhotoLibrarySaver;

@protocol PhotoLibrarySaverDelegate <NSObject>
// Called on the main thread. A nil message means the photo was saved.
- (void)photoLibrarySaver:(PhotoLibrarySaver *)saver didFinishWithErrorMessage:(NSString *)errorMessage;
@end

@interface PhotoLibrarySaver : NSObject {
    id<PhotoLibrarySaverDelegate> _delegate;
    ALAssetsLibrary *_photoLibrary;
    NSData *_photoSaveData;
    BOOL _saving;
}
@property(nonatomic, assign) id<PhotoLibrarySaverDelegate> delegate;
@property(nonatomic, readonly, getter=isSaving) BOOL saving;
// Call on the main thread. Returns NO if a save is already in progress.
// The worker and library callback keep the operation alive until it finishes.
- (BOOL)savePhotoAtPath:(NSString *)path;
@end
