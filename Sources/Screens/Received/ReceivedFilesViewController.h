#import <UIKit/UIKit.h>
#import <QuickLook/QuickLook.h>
#import "PhotoLibrarySaver.h"

@interface ReceivedFilesViewController
    : UITableViewController <UIActionSheetDelegate, QLPreviewControllerDataSource,
                             UIDocumentInteractionControllerDelegate, PhotoLibrarySaverDelegate> {
    NSArray *_files;
    NSDictionary *_selectedFile;
    NSURL *_previewURL;
    UIDocumentInteractionController *_documentInteractionController;
    UIBarButtonItem *_cancelReceiveButton;
    UIView *_emptyStateView;
    NSString *_receiveStatus;
    BOOL _isReceivingFiles;
    UIActionSheet *_fileActionsSheet;
    PhotoLibrarySaver *_photoSaver;
    UIView *_photoSaveOverlay;
}
- (id)initWithReceiveStatus:(NSString *)status active:(BOOL)active;
- (void)refreshBadge;
@end
