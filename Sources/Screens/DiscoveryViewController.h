#import <UIKit/UIKit.h>
#import "LocalSendPhotoPickerViewController.h"
#import "LocalSendDeviceListViewController.h"

@class LocalSendTransfer;
@class LocalSendRadarBackgroundView;
@class LocalSendAnimatedRadarView;

@interface DiscoveryViewController : UIViewController <UIActionSheetDelegate, LocalSendPhotoPickerDelegate,
                                                       LocalSendDeviceListDelegate, UIAlertViewDelegate> {
    NSArray *_devices;
    NSMutableDictionary *_blobViewsByIdentifier;
    NSDictionary *_blobPlacements;
    NSMutableArray *_retiringBlobViews;
    LocalSendRadarBackgroundView *_backgroundView;
    LocalSendAnimatedRadarView *_radarView;
    UIImageView *_wifiOffView;
    UILabel *_statusLabel;
    NSDictionary *_selectedDevice;
    LocalSendTransfer *_transfer;
    NSString *_outgoingTransferStatus;
    BOOL _isSendingFiles;
    NSString *_lastErrorMessage;
    UIAlertView *_receiveConfirmationAlert;
    UIAlertView *_insecureTransferAlert;
    NSInteger _pendingInsecureAction;
    NSString *_pendingReceiveRequestIdentifier;
    NSString *_receiveStatus;
    BOOL _isReceivingFiles;
    BOOL _receivingPreventsSleep;
    BOOL _previousIdleTimerDisabled;
    BOOL _wifiUnavailable;
    BOOL _radarScreenVisible;
    BOOL _observingNotifications;
}
@end
