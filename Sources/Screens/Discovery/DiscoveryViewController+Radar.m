#import "DiscoveryViewController+Private.h"
#import "Discovery.h"
#import "RadarBackgroundView.h"
#import "AnimatedRadarView.h"
#import "RadarLayout.h"
#import "DeviceBlobView.h"

@implementation DiscoveryViewController (Radar)

- (void)createRadar {
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithTitle:@"Refresh"
                                                                style:UIBarButtonItemStyleBordered
                                                               target:self
                                                               action:@selector(refresh:)];
    self.navigationItem.rightBarButtonItem = refresh;
    [refresh release];

    _radarView = [[AnimatedRadarView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 250.0f, 250.0f)];
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
    _statusLabel.text = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad
        ? @"Searching for devices…" : @"Searching for devices....";
    _statusLabel.userInteractionEnabled = YES;
    UITapGestureRecognizer *statusTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showLastError:)];
    [_statusLabel addGestureRecognizer:statusTap];
    [statusTap release];
    [self.view addSubview:_statusLabel];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        _statusLabel.font = [UIFont boldSystemFontOfSize:28.0f];
        _statusLabel.textColor = [UIColor colorWithWhite:0.96f alpha:1.0f];
        _discoveryHintLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _discoveryHintLabel.backgroundColor = [UIColor clearColor];
        _discoveryHintLabel.textAlignment = UITextAlignmentCenter;
        _discoveryHintLabel.font = [UIFont systemFontOfSize:16.0f];
        _discoveryHintLabel.textColor = [UIColor colorWithWhite:0.82f alpha:1.0f];
        _discoveryHintLabel.text = @"Nearby devices will appear here automatically.";
        [self.view addSubview:_discoveryHintLabel];
    }
}

- (void)layoutMainScreen {
    CGRect bounds = self.view.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    _backgroundView.frame = bounds;
    CGFloat radarCenterY = [RadarLayout radarCenterYInBounds:bounds];
    _radarView.center = CGPointMake(width / 2.0f, radarCenterY);
    _wifiOffView.center = CGPointMake(width / 2.0f, radarCenterY);
    _statusLabel.frame = CGRectMake(6.0f, radarCenterY + (_wifiUnavailable ? 88.0f : 78.0f),
                                    width - 12.0f, 32.0f);
    if (_discoveryHintLabel != nil) {
        _statusLabel.frame = CGRectMake(20, radarCenterY + 101, width - 40, 38);
        _discoveryHintLabel.frame = CGRectMake(12, radarCenterY + 153, width - 24, 22);
        _discoveryHintLabel.hidden = _wifiUnavailable || _isSendingFiles || _isReceivingFiles || _contactBackup != nil;
    }
}

- (void)updateWiFiState {
    BOOL unavailable = ![[Discovery sharedDiscovery] hasLocalNetworkInterface];
    BOOL changed = _wifiUnavailable != unavailable;
    _wifiUnavailable = unavailable;
    _wifiOffView.hidden = !unavailable;
    _radarView.hidden = unavailable;
    if (unavailable) {
        [_radarView stopAnimating];
        if (UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPad) {
            self.navigationItem.leftBarButtonItem = nil;
        }
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

- (void)deviceBlobPressed:(DeviceBlobView *)blob {
    if (_contactBackup != nil) return;
    [_selectedDevice release];
    _selectedDevice = [blob.device copy];
    [self showSendActionsForSelectedDevice];
}

- (void)showAllDevices:(id)sender {
    DeviceListViewController *list =
        [[DeviceListViewController alloc] initWithDevices:_devices delegate:self];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:list];
    navigation.navigationBar.barStyle = UIBarStyleBlack;
    [self presentModalViewController:navigation animated:YES];
    [navigation release];
    [list release];
}

- (void)deviceListViewController:(DeviceListViewController *)controller
                 didChooseDevice:(NSDictionary *)device {
    [_selectedDevice release];
    _selectedDevice = [device copy];
    [self dismissModalViewControllerAnimated:YES];
    [self performSelector:@selector(showSendActionsForSelectedDevice) withObject:nil afterDelay:0.35f];
}

- (void)removeBlobAfterAnimation:(DeviceBlobView *)blob {
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
        [currentIdentifiers addObject:[RadarLayout identifierForDevice:device]];
    }
    for (NSString *identifier in [_blobViewsByIdentifier allKeys]) {
        if (![currentIdentifiers containsObject:identifier]) {
            DeviceBlobView *blob = [_blobViewsByIdentifier objectForKey:identifier];
            [self removeBlobAfterAnimation:blob];
            [_blobViewsByIdentifier removeObjectForKey:identifier];
        }
    }

    NSMutableArray *reservedFrames = [NSMutableArray array];
    if (_discoveryHintLabel != nil) {
        CGRect textArea = CGRectUnion(_statusLabel.frame, _discoveryHintLabel.frame);
        [reservedFrames addObject:[NSValue valueWithBytes:&textArea objCType:@encode(CGRect)]];
    }
    for (DeviceBlobView *retiring in _retiringBlobViews) {
        CGRect frame = retiring.frame;
        [reservedFrames addObject:[NSValue valueWithBytes:&frame objCType:@encode(CGRect)]];
    }
    NSDictionary *placements = [RadarLayout placementsForDevices:_devices
                                                                 inBounds:self.view.bounds
                                                       previousPlacements:_blobPlacements
                                                           reservedFrames:reservedFrames];
    [_blobPlacements release];
    _blobPlacements = [placements copy];

    for (NSDictionary *device in _devices) {
        NSString *identifier = [RadarLayout identifierForDevice:device];
        NSDictionary *placement = [placements objectForKey:identifier];
        DeviceBlobView *blob = [_blobViewsByIdentifier objectForKey:identifier];
        if (placement == nil) {
            if (blob != nil) {
                [self removeBlobAfterAnimation:blob];
                [_blobViewsByIdentifier removeObjectForKey:identifier];
            }
            continue;
        }
        CGRect frame = [RadarLayout frameForPlacement:placement];
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

        blob = [[DeviceBlobView alloc]
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
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        BOOL showOverflow = !_wifiUnavailable && overflowCount > 0;
        if (showOverflow) {
            UIBarButtonItem *more = [[[UIBarButtonItem alloc]
                initWithTitle:[NSString stringWithFormat:@"%lu more devices", (unsigned long)overflowCount]
                style:UIBarButtonItemStyleBordered target:self action:@selector(showAllDevices:)] autorelease];
            self.toolbarItems = [NSArray arrayWithObject:more];
        }
        if (self.navigationController.toolbarHidden == showOverflow) {
            [self.navigationController setToolbarHidden:!showOverflow animated:NO];
        }
        return;
    }
    if (_wifiUnavailable || overflowCount == 0) {
        if (UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPad) {
            self.navigationItem.leftBarButtonItem = nil;
        }
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
@end
