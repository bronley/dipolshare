#import "DiscoveryViewController.h"
#import "DeviceListViewController.h"
#import "PhotoPickerViewController.h"
#import "ContactBackup.h"

@class DeviceBlobView;

// Internal declarations shared by the controller implementation files.
@interface DiscoveryViewController ()
- (void)updateStatusLabel;
- (void)refresh:(id)sender;
- (void)reloadDevices;
- (void)showLastError:(UITapGestureRecognizer *)recognizer;
@end

@interface DiscoveryViewController (Radar) <DeviceListDelegate>
- (void)createRadar;
- (void)layoutMainScreen;
- (void)updateWiFiState;
- (void)deviceBlobPressed:(DeviceBlobView *)blob;
- (void)showAllDevices:(id)sender;
- (void)deviceListViewController:(DeviceListViewController *)controller
                 didChooseDevice:(NSDictionary *)device;
- (void)removeBlobAfterAnimation:(DeviceBlobView *)blob;
- (void)synchronizeDeviceBlobs;
@end

@interface DiscoveryViewController (Sending) <UIActionSheetDelegate, PhotoPickerDelegate>
- (void)choosePhotos:(id)sender;
- (void)sendClipboard:(id)sender;
- (void)photoPicker:(PhotoPickerViewController *)picker
    didSelectAssets:(NSArray *)assets
            library:(ALAssetsLibrary *)library;
- (void)photoPickerDidCancel:(PhotoPickerViewController *)picker;
- (void)transferUpdated:(NSNotification *)notification;
- (void)showSendActionsForSelectedDevice;
- (void)showMoreActions;
- (void)dismissSendActions;
- (void)dismissInsecureTransferAlert;
- (void)performSendActionAtIndex:(NSInteger)index;
- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex;
@end

@interface DiscoveryViewController (Contacts) <ContactBackupDelegate>
- (void)prepareContactBackup;
- (void)contactBackupDidFinish:(ContactBackup *)backup;
- (void)dismissContactBackup;
@end

@interface DiscoveryViewController (Receiving)
- (void)dismissReceiveAlert;
- (void)receiveRequestChanged:(NSNotification *)notification;
- (void)receiveUpdated:(NSNotification *)notification;
- (void)updateReceiveIdleTimer;
- (void)restoreReceiveIdleTimer;
- (void)receiveEnteredBackground:(NSNotification *)notification;
@end

static inline NSString *DisplayNameForReceivePrompt(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) {
        return @"Unknown";
    }
    NSString *display = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
        componentsJoinedByString:@" "];
    if ([display length] > 80) {
        display = [[display substringToIndex:77] stringByAppendingString:@"…"];
    }
    return display;
}
