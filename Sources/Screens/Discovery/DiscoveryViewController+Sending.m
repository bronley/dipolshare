#import "DiscoveryViewController+Private.h"
#import "Transfer.h"
#import "RadarLayout.h"
#import "DeviceBlobView.h"
#import "AnimatedRadarView.h"

static const NSInteger MoreActionsTag = 1001;
static const NSInteger ContactsAction = 2;

@implementation DiscoveryViewController (Sending)

- (void)choosePhotos:(id)sender {
    if (_selectedDevice == nil) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Choose a device"
                                                        message:@"Tap a nearby device before choosing photos."
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil];
        [alert show];
        [alert release];
        return;
    }
    PhotoPickerViewController *picker =
        [[PhotoPickerViewController alloc] initWithDelegate:self];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:picker];
    navigation.navigationBar.barStyle = UIBarStyleBlack;
    [self presentModalViewController:navigation animated:YES];
    [navigation release];
    [picker release];
}

- (void)sendClipboard:(id)sender {
    if (_selectedDevice == nil) {
        return;
    }
    // Read only when the user chooses Send Clipboard; snapshot it for this transfer.
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    NSString *text = pasteboard.string;
    if ([text length] == 0) {
        text = [pasteboard.URL absoluteString];
    }
    if ([text length] == 0) {
        UIAlertView *alert =
            [[UIAlertView alloc] initWithTitle:@"No clipboard text"
                                       message:@"Copy some text or a link, then choose Send Clipboard."
                                      delegate:nil
                             cancelButtonTitle:@"OK"
                             otherButtonTitles:nil];
        [alert show];
        [alert release];
        return;
    }
    [_transfer cancel];
    [_transfer release];
    _transfer = [[Transfer alloc] initWithDevice:_selectedDevice clipboardText:text];
    [_transfer start];
}

- (void)photoPicker:(PhotoPickerViewController *)picker
    didSelectAssets:(NSArray *)assets
            library:(ALAssetsLibrary *)library {
    [_transfer cancel];
    [_transfer release];
    _transfer = [[Transfer alloc] initWithDevice:_selectedDevice photoAssets:assets library:library];
    [self dismissModalViewControllerAnimated:YES];
    [_transfer start];
}

- (void)photoPickerDidCancel:(PhotoPickerViewController *)picker {
    [self dismissModalViewControllerAnimated:YES];
}

- (void)transferUpdated:(NSNotification *)notification {
    if ([notification object] != _transfer) {
        return;
    }
    NSDictionary *progress = [notification userInfo];
    NSString *status = [progress objectForKey:@"status"];
    [_outgoingTransferStatus release];
    _outgoingTransferStatus = [status copy];
    _isSendingFiles = [[progress objectForKey:@"isActive"] boolValue];
    _discoveryHintLabel.hidden = _wifiUnavailable || _isSendingFiles || _isReceivingFiles || _contactBackup != nil;
    if ([[progress objectForKey:@"isError"] boolValue]) {
        [_lastErrorMessage release];
        _lastErrorMessage = [status copy];
    }
    if (!_isReceivingFiles && !_wifiUnavailable) {
        _statusLabel.text = status;
    }
}

- (void)showSendActionsForSelectedDevice {
    if (_contactBackup != nil || _selectedDevice == nil) return;
    [self dismissSendActions];
    _sendActionsSheet = [[UIActionSheet alloc] initWithTitle:[_selectedDevice objectForKey:@"alias"]
                                                         delegate:self
                                                cancelButtonTitle:@"Cancel"
                                           destructiveButtonTitle:nil
                                                otherButtonTitles:@"Send Photos & Videos", @"Send Clipboard", @"More...", nil];
    [self presentSendActionsSheet];
}

- (void)showMoreActions {
    [self dismissSendActions];
    NSString *title = [NSString stringWithFormat:@"%@ · More",
        DisplayNameForReceivePrompt([_selectedDevice objectForKey:@"alias"])];
    _sendActionsSheet = [[UIActionSheet alloc] initWithTitle:title delegate:self
        cancelButtonTitle:@"Cancel" destructiveButtonTitle:nil otherButtonTitles:@"Back Up Contacts", nil];
    _sendActionsSheet.tag = MoreActionsTag;
    [self presentSendActionsSheet];
}

- (void)presentSendActionsSheet {
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        NSString *identifier = [RadarLayout identifierForDevice:_selectedDevice];
        DeviceBlobView *blob = [_blobViewsByIdentifier objectForKey:identifier];
        if (blob.superview != nil && !blob.hidden) {
            CGRect anchor = [blob convertRect:blob.bounds toView:self.view];
            [_sendActionsSheet showFromRect:anchor inView:self.view animated:YES];
        } else if (!self.navigationController.toolbarHidden && [self.toolbarItems count] > 0) {
            [_sendActionsSheet showFromBarButtonItem:[self.toolbarItems objectAtIndex:0] animated:YES];
        } else {
            [_sendActionsSheet showFromRect:[_radarView convertRect:_radarView.bounds toView:self.view]
                           inView:self.view animated:YES];
        }
    } else {
        [_sendActionsSheet showFromTabBar:self.tabBarController.tabBar];
    }
}

- (void)dismissSendActions {
    _sendActionsSheet.delegate = nil;
    [_sendActionsSheet dismissWithClickedButtonIndex:_sendActionsSheet.cancelButtonIndex animated:NO];
    [_sendActionsSheet release];
    _sendActionsSheet = nil;
}

- (void)dismissInsecureTransferAlert {
    if (_insecureTransferAlert == nil) {
        return;
    }
    _insecureTransferAlert.delegate = nil;
    [_insecureTransferAlert dismissWithClickedButtonIndex:_insecureTransferAlert.cancelButtonIndex
                                                 animated:NO];
    [_insecureTransferAlert release];
    _insecureTransferAlert = nil;
    _pendingInsecureAction = -1;
}

- (void)performSendActionAtIndex:(NSInteger)index {
    if (index == 0) {
        [self choosePhotos:nil];
    } else if (index == 1) {
        [self sendClipboard:nil];
    } else if (index == ContactsAction) {
        [self prepareContactBackup];
    }
}

- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex {
    if (actionSheet != _sendActionsSheet) return;
    BOOL more = actionSheet.tag == MoreActionsTag;
    BOOL cancelled = buttonIndex == actionSheet.cancelButtonIndex || buttonIndex < 0;
    _sendActionsSheet.delegate = nil;
    [_sendActionsSheet release];
    _sendActionsSheet = nil;
    if (cancelled || !_radarScreenVisible ||
        [UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    // Present the second sheet only after the first has finished dismissing.
    if (!more && buttonIndex == 2) {
        [self showMoreActions];
        return;
    }
    NSInteger action = more ? ContactsAction : buttonIndex;
    if ([[_selectedDevice objectForKey:@"protocol"] isEqualToString:@"http"]) {
        _pendingInsecureAction = action;
        _insecureTransferAlert = [[UIAlertView alloc]
            initWithTitle:@"Send without encryption?"
                  message:@"This device uses HTTP. Content sent to it, including contacts, may be visible to others on this network."
                 delegate:self
        cancelButtonTitle:@"Cancel"
        otherButtonTitles:@"Send Anyway", nil];
        [_insecureTransferAlert show];
        return;
    }
    [self performSendActionAtIndex:action];
}
@end
