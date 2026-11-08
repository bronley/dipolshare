#import "DiscoveryViewController+Private.h"
#import "Discovery.h"
#import "Transfer.h"
#import "Receiver.h"
#import "RadarBackgroundView.h"
#import "AnimatedRadarView.h"

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

    _backgroundView = [[RadarBackgroundView alloc] initWithFrame:self.view.bounds];
    _backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _backgroundView.contentMode = UIViewContentModeRedraw;
    [self.view addSubview:_backgroundView];

    [self createRadar];
    [self layoutMainScreen];
    [self observeTransferAndDiscoveryChanges];

    [self receiveRequestChanged:nil];
    [self refresh:nil];
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
                                                     name:DiscoveryDevicesDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(setupChanged:)
                                                     name:DiscoverySetupDidChangeNotification
                                                   object:[Discovery sharedDiscovery]];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(transferUpdated:)
                                                     name:TransferDidUpdateNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(receiveRequestChanged:)
                                                     name:ReceiveRequestNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(receiveUpdated:)
                                                     name:ReceiveProgressNotification
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
    [[Discovery sharedDiscovery] start];
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
    [self dismissSendActions];
    [self dismissContactBackup];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [_radarView stopAnimating];
    [self dismissInsecureTransferAlert];
    [self dismissSendActions];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (_radarScreenVisible) {
        [self layoutMainScreen];
        [self synchronizeDeviceBlobs];
        [self updateStatusLabel];
        if (!_wifiUnavailable) {
            [_radarView startAnimating];
        }
        if (_contactBackupReady && _contactBackupAlert == nil) {
            [self contactBackupDidFinish:_contactBackup];
        }
    }
}

- (void)refresh:(id)sender {
    if (!_isSendingFiles) {
        [_outgoingTransferStatus release];
        _outgoingTransferStatus = nil;
    }
    [[Discovery sharedDiscovery] refresh];
    [self reloadDevices];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView == _contactBackupAlert) {
        if (buttonIndex == 1 && _contactBackup != nil &&
            [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            NSString *path = [_contactBackup takeFilePath];
            if (path != nil) {
                [_transfer cancel];
                [_transfer release];
                _transfer = [[Transfer alloc] initWithDevice:_contactBackupDevice
                    contactsFileAtPath:path fileName:_contactBackup.fileName];
                [_transfer start];
            }
        }
        [self dismissContactBackup];
        [self updateStatusLabel];
        return;
    }
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
    NSDictionary *pending = [[Receiver sharedReceiver] pendingRequest];
    if ([requestIdentifier isEqualToString:[pending objectForKey:@"requestId"]]) {
        [[Receiver sharedReceiver] respondToRequest:requestIdentifier accept:(buttonIndex == 1)];
    }
    [requestIdentifier release];
}

- (void)alertViewCancel:(UIAlertView *)alertView {
    [self alertView:alertView clickedButtonAtIndex:alertView.cancelButtonIndex];
}

- (void)deviceListChanged:(NSNotification *)notification {
    [self reloadDevices];
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

- (void)reloadDevices {
    [_devices release];
    _devices = [[[Discovery sharedDiscovery] devices] copy];
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
    if (_contactBackup != nil) {
        _statusLabel.text = @"Preparing contacts…";
        return;
    }
    if ([_outgoingTransferStatus length] > 0) {
        _statusLabel.text = _outgoingTransferStatus;
        return;
    }
    if ([[Discovery sharedDiscovery] isFirstSetupInProgress]) {
        _statusLabel.text = @"First setup. Please wait.";
        return;
    }
    if ([[Discovery sharedDiscovery] identitySetupError] != nil) {
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
    [self dismissSendActions];
    [self dismissContactBackup];
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
