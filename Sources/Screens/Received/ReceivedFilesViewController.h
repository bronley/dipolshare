#import <UIKit/UIKit.h>
#import <QuickLook/QuickLook.h>
#import "PhotoLibrarySaver.h"
@class LocalSendPhotoPreviewViewController;

@interface ReceivedFilesViewController
    : UITableViewController <UIActionSheetDelegate, UIAlertViewDelegate, QLPreviewControllerDataSource,
                             UIDocumentInteractionControllerDelegate, PhotoLibrarySaverDelegate> {
    NSArray *_files;
    NSMutableSet *_selectedFilePaths;
    BOOL _selectingFiles;
    NSArray *_savingPhotoPaths;
    NSArray *_pendingDeletePaths;
    NSString *_swipedFilePath;
    UIAlertView *_deleteConfirmationAlert;
    NSDictionary *_selectedFile;
    NSURL *_previewURL;
    UIDocumentInteractionController *_documentInteractionController;
    UIBarButtonItem *_cancelReceiveButton;
    UIView *_emptyStateView;
    BOOL _isReceivingFiles;
    UIActionSheet *_fileActionsSheet;
    PhotoLibrarySaver *_photoSaver;
    UIView *_photoSaveOverlay;
    LocalSendPhotoPreviewViewController *_photoPreview;
}
- (id)initWithReceiveActive:(BOOL)active;
- (void)refreshBadge;
@end
