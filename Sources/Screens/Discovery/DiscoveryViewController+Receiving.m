#import "DiscoveryViewController+Private.h"
#import "Receiver.h"
#import "Sounds.h"
#import "Formatting.h"

@implementation DiscoveryViewController (Receiving)

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
    NSDictionary *request = [[Receiver sharedReceiver] pendingRequest];
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
                         DisplayNameForReceivePrompt([request objectForKey:@"senderAlias"]),
                         (unsigned long)[files count], [files count] == 1 ? @"" : @"s",
                         FormattedFileSize(
                             [[request objectForKey:@"totalBytes"] unsignedLongLongValue])];
    NSUInteger displayedFileCount = MIN((NSUInteger)3, [files count]);
    for (NSUInteger i = 0; i < displayedFileCount; i++) {
        [message appendFormat:@"\n%@", DisplayNameForReceivePrompt(
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
    [Sounds playIncomingTransfer];
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
    [self dismissContactBackup];
}
@end
