#import "DiscoveryViewController.h"
#import "LocalSendDiscovery.h"
#import "LocalSendTransfer.h"
#import "LocalSendReceiver.h"
#import "LocalSendReceivedFilesViewController.h"
#import "LocalSendSounds.h"
#import "LocalSendFormatting.h"
#import "LocalSendRadarBackgroundView.h"
#import "LocalSendAnimatedRadarView.h"
#import "LocalSendRadarLayout.h"
#import "LocalSendDeviceBlobView.h"
#import "LocalSendDeviceListViewController.h"
#import "LocalSendSettingsViewController.h"

static NSString *LocalSendDisplayNameForReceivePrompt(NSString *name) {
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

@interface DiscoveryViewController ()
- (void)createRadar;
- (void)layoutMainScreen;
- (void)updateWiFiState;
- (void)synchronizeDeviceBlobs;
- (void)removeBlobAfterAnimation:(LocalSendDeviceBlobView *)blob;
- (void)deviceBlobPressed:(LocalSendDeviceBlobView *)blob;
- (void)showAllDevices:(id)sender;
- (void)observeTransferAndDiscoveryChanges;
- (void)updateStatusLabel;
- (void)refresh:(id)sender;
- (void)reloadDevices;
- (void)choosePhotos:(id)sender;
- (void)sendClipboard:(id)sender;
- (void)showSendActionsForSelectedDevice;
- (void)dismissInsecureTransferAlert;
- (void)performSendActionAtIndex:(NSInteger)index;
- (void)showLastError:(UITapGestureRecognizer *)recognizer;
- (void)receiveRequestChanged:(NSNotification *)notification;
- (void)receiveUpdated:(NSNotification *)notification;
- (void)setupChanged:(NSNotification *)notification;
- (void)dismissReceiveAlert;
- (void)updateReceiveIdleTimer;
- (void)restoreReceiveIdleTimer;
- (void)receiveEnteredBackground:(NSNotification *)notification;
- (void)applicationWillResignActive:(NSNotification *)notification;
- (void)applicationDidBecomeActive:(NSNotification *)notification;
@end

@implementation DiscoveryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.17f alpha:1.0f];
    if (_devices == nil) {
        _devices = [[NSArray alloc] init];
    }
    if (_blobViewsByIdentifier == nil) {
        _blobViewsByIdentifier = [[NSMutableDictionary alloc] init];
    }
    if (_retiringBlobViews == nil) {
        _retiringBlobViews = [[NSMutableArray alloc] init];
    }

    _backgroundView = [[LocalSendRadarBackgroundView alloc] initWithFrame:self.view.bounds];
    _backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _backgroundView.contentMode = UIViewContentModeRedraw;
    [self.view addSubview:_backgroundView];

    [self createRadar];
    [self layoutMainScreen];
    [self observeTransferAndDiscoveryChanges];

    [self receiveRequestChanged:nil];
    [self refresh:nil];
}

- (void)createRadar {
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithTitle:@"Refresh"
                                                                style:UIBarButtonItemStyleBordered
                                                               target:self
                                                               action:@selector(refresh:)];
    self.navigationItem.rightBarButtonItem = refresh;
    [refresh release];

    _radarView = [[LocalSendAnimatedRadarView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 250.0f, 250.0f)];
    [self.view addSubview:_radarView];

    _wifiOffView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"WiFiOff"]];
    _wifiOffView.contentMode = UIViewContentModeScaleAspectFit;
    _wifiOffView.hidden = YES;
    [self.view addSubview:_wifiOffView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.backgroundColor = [UIColor clearColor];
    _statusLabel.textAlignment = UITextAlignmentCenter;
    _statusLabel.font = [UIFont boldSystemFontOfSize:15.5f];
    _statusLabel.textColor = [UIColor colorWithWhite:0.85f alpha:1.0f];
    _statusLabel.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.35f];
    _statusLabel.shadowOffset = CGSizeMake(0.0f, 1.0f);
    _statusLabel.adjustsFontSizeToFitWidth = YES;
    _statusLabel.minimumFontSize = 11.0f;
    _statusLabel.text = @"Searching for devices....";
    _statusLabel.userInteractionEnabled = YES;
    UITapGestureRecognizer *statusTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showLastError:)];
    [_statusLabel addGestureRecognizer:statusTap];
    [statusTap release];
    [self.view addSubview:_statusLabel];
}

- (void)layoutMainScreen {
    CGRect bounds = self.view.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    _backgroundView.frame = bounds;
    CGFloat radarCenterY = [LocalSendRadarLayout radarCenterYInBounds:bounds];
    _radarView.center = CGPointMake(width / 2.0f, radarCenterY);
    _wifiOffView.center = CGPointMake(width / 2.0f, radarCenterY);
    _statusLabel.frame = CGRectMake(6.0f, radarCenterY + (_wifiUnavailable ? 88.0f : 78.0f),
                                    width - 12.0f, 32.0f);
}

- (void)updateWiFiState {
    BOOL unavailable = ![[LocalSendDiscovery sharedDiscovery] hasLocalNetworkInterface];
    BOOL changed = _wifiUnavailable != unavailable;
    _wifiUnavailable = unavailable;
    _wifiOffView.hidden = !unavailable;
    _radarView.hidden = unavailable;
    if (unavailable) {
        [_radarView stopAnimating];
        self.navigationItem.leftBarButtonItem = nil;
    } else {
        if (changed) {
            [self synchronizeDeviceBlobs];
        }
        if (_radarScreenVisible &&
            [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            [_radarView startAnimating];
        }
    }
    for (UIView *blob in [_blobViewsByIdentifier allValues]) {
        blob.hidden = unavailable;
    }
    for (UIView *blob in _retiringBlobViews) {
        blob.hidden = unavailable;
    }
    [self layoutMainScreen];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_backgroundView != nil) {
        [self layoutMainScreen];
        [self synchronizeDeviceBlobs];
    }
}

- (void)observeTransferAndDiscoveryChanges {
    if (!_observingNotifications) {
        _observingNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(deviceListChanged:)
                                                     name:LocalSendDiscoveryDevicesDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(setupChanged:)
                                                     name:LocalSendDiscoverySetupDidChangeNotification
                                                   object:[LocalSendDiscovery sharedDiscovery]];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(transferUpdated:)
                                                     name:LocalSendTransferDidUpdateNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(receiveRequestChanged:)
                                                     name:LocalSendReceiveRequestNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(receiveUpdated:)
                                                     name:LocalSendReceiveProgressNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(receiveEnteredBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillResignActive:)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self layoutMainScreen];
    [self synchronizeDeviceBlobs];
    [[LocalSendDiscovery sharedDiscovery] start];
    [self reloadDevices];
    [self receiveRequestChanged:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // iOS 4 does not call viewDidLayoutSubviews; the tab and navigation bars
    // may have resized this view after its initial layout in viewDidLoad.
    [self layoutMainScreen];
    [self synchronizeDeviceBlobs];
    _radarScreenVisible = YES;
    [self updateStatusLabel];
    if (!_wifiUnavailable &&
        [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        [_radarView startAnimating];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    _radarScreenVisible = NO;
    [_radarView stopAnimating];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [_radarView stopAnimating];
    [self dismissInsecureTransferAlert];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (_radarScreenVisible) {
        [self layoutMainScreen];
        [self synchronizeDeviceBlobs];
        [self updateStatusLabel];
        if (!_wifiUnavailable) {
            [_radarView startAnimating];
        }
    }
}

- (void)refresh:(id)sender {
    [[LocalSendDiscovery sharedDiscovery] refresh];
    [self reloadDevices];
}

- (void)dismissReceiveAlert {
    // Disable callbacks first: a stale or cancelled request must never be accepted.
    _receiveConfirmationAlert.delegate = nil;
    [_receiveConfirmationAlert dismissWithClickedButtonIndex:_receiveConfirmationAlert.cancelButtonIndex
                                                    animated:NO];
    [_receiveConfirmationAlert release];
    _receiveConfirmationAlert = nil;
    [_pendingReceiveRequestIdentifier release];
    _pendingReceiveRequestIdentifier = nil;
}

- (void)receiveRequestChanged:(NSNotification *)notification {
    NSDictionary *request = [[LocalSendReceiver sharedReceiver] pendingRequest];
    NSString *requestIdentifier = [request objectForKey:@"requestId"];
    if (_receiveConfirmationAlert != nil &&
        [_pendingReceiveRequestIdentifier isEqualToString:requestIdentifier]) {
        return;
    }
    [self dismissReceiveAlert];
    if (![requestIdentifier isKindOfClass:[NSString class]] || [requestIdentifier length] == 0) {
        return;
    }

    NSArray *files = [request objectForKey:@"files"];
    NSMutableString *message = [NSMutableString
        stringWithFormat:@"%@ wants to send %lu file%@ (%@).\n",
                         LocalSendDisplayNameForReceivePrompt([request objectForKey:@"senderAlias"]),
                         (unsigned long)[files count], [files count] == 1 ? @"" : @"s",
                         LocalSendFormattedFileSize(
                             [[request objectForKey:@"totalBytes"] unsignedLongLongValue])];
    NSUInteger displayedFileCount = MIN((NSUInteger)3, [files count]);
    for (NSUInteger i = 0; i < displayedFileCount; i++) {
        [message appendFormat:@"\n%@", LocalSendDisplayNameForReceivePrompt(
                                           [[files objectAtIndex:i] objectForKey:@"fileName"])];
    }
    if ([files count] > displayedFileCount) {
        [message appendFormat:@"\n…and %lu more", (unsigned long)([files count] - displayedFileCount)];
    }
    [message appendString:@"\n\nSave to Received?"];
    _pendingReceiveRequestIdentifier = [requestIdentifier copy];
    _receiveConfirmationAlert = [[UIAlertView alloc] initWithTitle:@"Receive files?"
                                                           message:message
                                                          delegate:self
                                                 cancelButtonTitle:@"Decline"
                                                 otherButtonTitles:@"Accept", nil];
    [_receiveConfirmationAlert show];
    [LocalSendSounds playIncomingTransfer];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView == _insecureTransferAlert) {
        NSInteger action = _pendingInsecureAction;
        _insecureTransferAlert.delegate = nil;
        [_insecureTransferAlert release];
        _insecureTransferAlert = nil;
        _pendingInsecureAction = -1;
        if (buttonIndex == 1) {
            [self performSendActionAtIndex:action];
        }
        return;
    }
    if (alertView != _receiveConfirmationAlert) {
        return;
    }
    NSString *requestIdentifier = [_pendingReceiveRequestIdentifier copy];
    _receiveConfirmationAlert.delegate = nil;
    [_receiveConfirmationAlert release];
    _receiveConfirmationAlert = nil;
    [_pendingReceiveRequestIdentifier release];
    _pendingReceiveRequestIdentifier = nil;
    NSDictionary *pending = [[LocalSendReceiver sharedReceiver] pendingRequest];
    if ([requestIdentifier isEqualToString:[pending objectForKey:@"requestId"]]) {
        [[LocalSendReceiver sharedReceiver] respondToRequest:requestIdentifier accept:(buttonIndex == 1)];
    }
    [requestIdentifier release];
}

- (void)alertViewCancel:(UIAlertView *)alertView {
    [self alertView:alertView clickedButtonAtIndex:alertView.cancelButtonIndex];
}

- (void)receiveUpdated:(NSNotification *)notification {
    NSDictionary *info = [notification userInfo];
    NSString *status = [info objectForKey:@"status"];
    [_receiveStatus release];
    _receiveStatus = [status copy];
    _isReceivingFiles = [[info objectForKey:@"active"] boolValue];
    [self updateReceiveIdleTimer];
    if ([status length] > 0 && !_wifiUnavailable) {
        _statusLabel.text = status;
    }
    if ([[info objectForKey:@"error"] boolValue]) {
        [_lastErrorMessage release];
        _lastErrorMessage = [status copy];
    }
}

- (void)updateReceiveIdleTimer {
    UIApplication *application = [UIApplication sharedApplication];
    BOOL keepAwake = _isReceivingFiles && application.applicationState != UIApplicationStateBackground;
    if (keepAwake && !_receivingPreventsSleep) {
        _previousIdleTimerDisabled = application.idleTimerDisabled;
        _receivingPreventsSleep = YES;
        application.idleTimerDisabled = YES;
    } else if (!keepAwake) {
        [self restoreReceiveIdleTimer];
    }
}

- (void)restoreReceiveIdleTimer {
    if (!_receivingPreventsSleep) {
        return;
    }
    [UIApplication sharedApplication].idleTimerDisabled = _previousIdleTimerDisabled;
    _receivingPreventsSleep = NO;
}

- (void)receiveEnteredBackground:(NSNotification *)notification {
    // Background cancellation can post its final progress later on the main queue.
    [self restoreReceiveIdleTimer];
}

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
    LocalSendPhotoPickerViewController *picker =
        [[LocalSendPhotoPickerViewController alloc] initWithDelegate:self];
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
    _transfer = [[LocalSendTransfer alloc] initWithDevice:_selectedDevice clipboardText:text];
    [_transfer start];
}

- (void)photoPicker:(LocalSendPhotoPickerViewController *)picker
    didSelectAssets:(NSArray *)assets
            library:(ALAssetsLibrary *)library {
    [_transfer cancel];
    [_transfer release];
    _transfer = [[LocalSendTransfer alloc] initWithDevice:_selectedDevice photoAssets:assets library:library];
    [self dismissModalViewControllerAnimated:YES];
    [_transfer start];
}

- (void)photoPickerDidCancel:(LocalSendPhotoPickerViewController *)picker {
    [self dismissModalViewControllerAnimated:YES];
}

- (void)deviceListChanged:(NSNotification *)notification {
    [self reloadDevices];
}

- (void)deviceBlobPressed:(LocalSendDeviceBlobView *)blob {
    [_selectedDevice release];
    _selectedDevice = [blob.device copy];
    [self showSendActionsForSelectedDevice];
}

- (void)showAllDevices:(id)sender {
    LocalSendDeviceListViewController *list =
        [[LocalSendDeviceListViewController alloc] initWithDevices:_devices delegate:self];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:list];
    navigation.navigationBar.barStyle = UIBarStyleBlack;
    [self presentModalViewController:navigation animated:YES];
    [navigation release];
    [list release];
}

- (void)deviceListViewController:(LocalSendDeviceListViewController *)controller
                 didChooseDevice:(NSDictionary *)device {
    [_selectedDevice release];
    _selectedDevice = [device copy];
    [self dismissModalViewControllerAnimated:YES];
    [self performSelector:@selector(showSendActionsForSelectedDevice) withObject:nil afterDelay:0.35f];
}

- (void)removeBlobAfterAnimation:(LocalSendDeviceBlobView *)blob {
    [_retiringBlobViews addObject:blob];
    [UIView animateWithDuration:0.28f
        delay:0.0f
        options:UIViewAnimationOptionCurveEaseIn
        animations:^{
            blob.alpha = 0.0f;
            blob.transform = CGAffineTransformMakeScale(0.7f, 0.7f);
        }
        completion:^(BOOL finished) {
            [blob removeFromSuperview];
            [_retiringBlobViews removeObject:blob];
            [self synchronizeDeviceBlobs];
        }];
}

- (void)synchronizeDeviceBlobs {
    if (_radarView == nil) {
        return;
    }
    NSMutableSet *currentIdentifiers = [NSMutableSet set];
    for (NSDictionary *device in _devices) {
        [currentIdentifiers addObject:[LocalSendRadarLayout identifierForDevice:device]];
    }
    for (NSString *identifier in [_blobViewsByIdentifier allKeys]) {
        if (![currentIdentifiers containsObject:identifier]) {
            LocalSendDeviceBlobView *blob = [_blobViewsByIdentifier objectForKey:identifier];
            [self removeBlobAfterAnimation:blob];
            [_blobViewsByIdentifier removeObjectForKey:identifier];
        }
    }

    NSMutableArray *reservedFrames = [NSMutableArray array];
    for (LocalSendDeviceBlobView *retiring in _retiringBlobViews) {
        CGRect frame = retiring.frame;
        [reservedFrames addObject:[NSValue valueWithBytes:&frame objCType:@encode(CGRect)]];
    }
    NSDictionary *placements = [LocalSendRadarLayout placementsForDevices:_devices
                                                                 inBounds:self.view.bounds
                                                       previousPlacements:_blobPlacements
                                                           reservedFrames:reservedFrames];
    [_blobPlacements release];
    _blobPlacements = [placements copy];

    for (NSDictionary *device in _devices) {
        NSString *identifier = [LocalSendRadarLayout identifierForDevice:device];
        NSDictionary *placement = [placements objectForKey:identifier];
        LocalSendDeviceBlobView *blob = [_blobViewsByIdentifier objectForKey:identifier];
        if (placement == nil) {
            if (blob != nil) {
                [self removeBlobAfterAnimation:blob];
                [_blobViewsByIdentifier removeObjectForKey:identifier];
            }
            continue;
        }
        CGRect frame = [LocalSendRadarLayout frameForPlacement:placement];
        if (blob != nil) {
            [blob updateDevice:device];
            if (!CGRectEqualToRect(blob.frame, frame)) {
                [UIView animateWithDuration:0.28f
                                 animations:^{
                                     blob.frame = frame;
                                 }];
            }
            continue;
        }

        blob = [[LocalSendDeviceBlobView alloc]
            initWithDevice:device
                colorIndex:[[placement objectForKey:@"colorIndex"] unsignedIntegerValue]
                     scale:[[placement objectForKey:@"scale"] floatValue]];
        blob.frame = frame;
        blob.hidden = _wifiUnavailable;
        blob.alpha = 0.7f;
        blob.transform = CGAffineTransformMakeScale(0.7f, 0.7f);
        [blob addTarget:self
                      action:@selector(deviceBlobPressed:)
            forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:blob];
        [_blobViewsByIdentifier setObject:blob forKey:identifier];
        [UIView animateWithDuration:0.38f
                              delay:0.0f
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
                             blob.alpha = 1.0f;
                             blob.transform = CGAffineTransformIdentity;
                         }
                         completion:nil];
        [blob release];
    }
    NSUInteger overflowCount = [_devices count] - [placements count];
    if (_wifiUnavailable || overflowCount == 0) {
        self.navigationItem.leftBarButtonItem = nil;
    } else {
        UIBarButtonItem *more = self.navigationItem.leftBarButtonItem;
        if (more == nil) {
            more = [[UIBarButtonItem alloc] initWithTitle:@""
                                                    style:UIBarButtonItemStyleBordered
                                                   target:self
                                                   action:@selector(showAllDevices:)];
            self.navigationItem.leftBarButtonItem = more;
            [more release];
        }
        more.title = [NSString stringWithFormat:@"%lu more", (unsigned long)overflowCount];
    }
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
    if ([[progress objectForKey:@"isError"] boolValue]) {
        [_lastErrorMessage release];
        _lastErrorMessage = [status copy];
    }
    if (!_isReceivingFiles && !_wifiUnavailable) {
        _statusLabel.text = status;
    }
}

- (void)showLastError:(UITapGestureRecognizer *)recognizer {
    if (_lastErrorMessage == nil) {
        return;
    }
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Transfer failed"
                                                    message:_lastErrorMessage
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
    [alert release];
}

- (void)showSendActionsForSelectedDevice {
    UIActionSheet *actions = [[UIActionSheet alloc] initWithTitle:[_selectedDevice objectForKey:@"alias"]
                                                         delegate:self
                                                cancelButtonTitle:@"Cancel"
                                           destructiveButtonTitle:nil
                                                otherButtonTitles:@"Send Photos", @"Send Clipboard", nil];
    [actions showFromTabBar:self.tabBarController.tabBar];
    [actions release];
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
    }
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex != 0 && buttonIndex != 1) {
        return;
    }
    if ([[_selectedDevice objectForKey:@"protocol"] isEqualToString:@"http"]) {
        _pendingInsecureAction = buttonIndex;
        _insecureTransferAlert = [[UIAlertView alloc]
            initWithTitle:@"Send without encryption?"
                  message:@"This device uses HTTP. Photos or clipboard text sent to it may be visible to others on this network."
                 delegate:self
        cancelButtonTitle:@"Cancel"
        otherButtonTitles:@"Send Anyway", nil];
        [_insecureTransferAlert show];
        return;
    }
    [self performSendActionAtIndex:buttonIndex];
}

- (void)reloadDevices {
    [_devices release];
    _devices = [[[LocalSendDiscovery sharedDiscovery] devices] copy];
    [self synchronizeDeviceBlobs];
    [self updateStatusLabel];
}

- (void)updateStatusLabel {
    [self updateWiFiState];
    if (_wifiUnavailable) {
        _statusLabel.text = @"No network";
        return;
    }
    if (_isReceivingFiles && [_receiveStatus length] > 0) {
        _statusLabel.text = _receiveStatus;
        return;
    }
    if (_isSendingFiles && [_outgoingTransferStatus length] > 0) {
        _statusLabel.text = _outgoingTransferStatus;
        return;
    }
    if ([[LocalSendDiscovery sharedDiscovery] isFirstSetupInProgress]) {
        _statusLabel.text = @"First setup. Please wait.";
        return;
    }
    if ([[LocalSendDiscovery sharedDiscovery] identitySetupError] != nil) {
        _statusLabel.text = @"Device key failed. See Settings.";
        return;
    }
    _statusLabel.text = @"Searching for devices....";
}

- (void)setupChanged:(NSNotification *)notification {
    [self updateStatusLabel];
}

- (void)viewDidUnload {
    _radarScreenVisible = NO;
    [_blobViewsByIdentifier release];
    _blobViewsByIdentifier = nil;
    [_retiringBlobViews release];
    _retiringBlobViews = nil;
    [_backgroundView release];
    _backgroundView = nil;
    [_radarView release];
    _radarView = nil;
    [_wifiOffView release];
    _wifiOffView = nil;
    [_statusLabel release];
    _statusLabel = nil;
    [super viewDidUnload];
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self restoreReceiveIdleTimer];
    [self dismissInsecureTransferAlert];
    [self dismissReceiveAlert];
    [_blobViewsByIdentifier release];
    [_blobPlacements release];
    [_retiringBlobViews release];
    [_backgroundView release];
    [_radarView release];
    [_wifiOffView release];
    [_receiveStatus release];
    [_transfer release];
    [_outgoingTransferStatus release];
    [_selectedDevice release];
    [_statusLabel release];
    [_devices release];
    [_lastErrorMessage release];
    [super dealloc];
}
@end
