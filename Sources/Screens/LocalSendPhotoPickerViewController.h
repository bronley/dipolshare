#import <UIKit/UIKit.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import "LocalSendPhotoGridCell.h"

@class LocalSendPhotoPickerViewController;

@protocol LocalSendPhotoPickerDelegate <NSObject>
- (void)photoPicker:(LocalSendPhotoPickerViewController *)picker
    didSelectAssets:(NSArray *)assets
            library:(ALAssetsLibrary *)library;
- (void)photoPickerDidCancel:(LocalSendPhotoPickerViewController *)picker;
@end

@interface LocalSendPhotoPickerViewController : UITableViewController <LocalSendPhotoGridCellDelegate> {
    ALAssetsLibrary *_library;
    NSMutableArray *_assets;
    NSOperationQueue *_photoLoadQueue;
    NSMutableArray *_loadingEntries;
    NSMutableSet *_loadedAssetURLs;
    NSMutableArray *_selectedAssets;
    UIBarButtonItem *_sendButton;
    NSError *_photoLibraryError;
    id<LocalSendPhotoPickerDelegate> _delegate;
    BOOL _isLoadingPhotos;
    BOOL _hasStartedLoading;
    BOOL _isClosed;
}
- (id)initWithDelegate:(id<LocalSendPhotoPickerDelegate>)delegate;
@end
