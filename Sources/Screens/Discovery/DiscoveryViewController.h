#import <UIKit/UIKit.h>

@class Transfer;
@class ContactBackup;
@class RadarBackgroundView;
@class AnimatedRadarView;

@interface DiscoveryViewController : UIViewController <UIAlertViewDelegate> {
    NSArray *_devices;
    NSMutableDictionary *_blobViewsByIdentifier;
    NSDictionary *_blobPlacements;
    NSMutableArray *_retiringBlobViews;
    RadarBackgroundView *_backgroundView;
    AnimatedRadarView *_radarView;
    UIImageView *_wifiOffView;
    UILabel *_statusLabel;
    UILabel *_discoveryHintLabel;
    NSDictionary *_selectedDevice;
    Transfer *_transfer;
    NSString *_outgoingTransferStatus;
    BOOL _isSendingFiles;
    NSString *_lastErrorMessage;
    UIAlertView *_receiveConfirmationAlert;
    UIAlertView *_insecureTransferAlert;
    NSInteger _pendingInsecureAction;
    UIActionSheet *_sendActionsSheet;
    ContactBackup *_contactBackup;
    NSDictionary *_contactBackupDevice;
    UIAlertView *_contactBackupAlert;
    BOOL _contactBackupReady;
    NSString *_pendingReceiveRequestIdentifier;
    NSString *_receiveStatus;
    BOOL _isReceivingFiles;
    BOOL _receivingPreventsSleep;
    BOOL _previousIdleTimerDisabled;
    BOOL _wifiUnavailable;
    BOOL _radarScreenVisible;
    BOOL _observingNotifications;
}
- (void)layoutForContainer;
@end
