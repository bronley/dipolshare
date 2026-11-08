#import <UIKit/UIKit.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import "PhotoGridCell.h"
#import "PhotoLibraryLoader.h"

@class PhotoPickerViewController;

@protocol PhotoPickerDelegate <NSObject>
- (void)photoPicker:(PhotoPickerViewController *)picker
    didSelectAssets:(NSArray *)assets
            library:(ALAssetsLibrary *)library;
- (void)photoPickerDidCancel:(PhotoPickerViewController *)picker;
@end

@interface PhotoPickerViewController : UITableViewController <PhotoGridCellDelegate, PhotoLibraryLoaderDelegate> {
    PhotoLibraryLoader *_photoLoader;
    NSMutableArray *_assets;
    NSMutableArray *_selectedAssets;
    UIBarButtonItem *_sendButton;
    NSError *_photoLibraryError;
    id<PhotoPickerDelegate> _delegate;
    BOOL _isLoadingPhotos;
    BOOL _isClosed;
}
- (id)initWithDelegate:(id<PhotoPickerDelegate>)delegate;
@end
