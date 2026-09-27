#import <UIKit/UIKit.h>
#import <QuickLook/QuickLook.h>
#import <AssetsLibrary/AssetsLibrary.h>

@interface LocalSendReceivedFilesViewController
    : UITableViewController <UIActionSheetDelegate, QLPreviewControllerDataSource,
                             UIDocumentInteractionControllerDelegate> {
    NSArray *_files;
    NSDictionary *_selectedFile;
    NSURL *_previewURL;
    UIDocumentInteractionController *_documentInteractionController;
    UIBarButtonItem *_cancelReceiveButton;
    UIView *_emptyStateView;
    NSString *_receiveStatus;
    BOOL _isReceivingFiles;
    UIActionSheet *_fileActionsSheet;
    ALAssetsLibrary *_photoLibrary;
    NSData *_photoSaveData;
    BOOL _isSavingPhoto;
}
- (id)initWithReceiveStatus:(NSString *)status active:(BOOL)active;
- (void)refreshBadge;
@end
