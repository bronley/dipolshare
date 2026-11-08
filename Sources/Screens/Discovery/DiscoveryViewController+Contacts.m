#import "DiscoveryViewController+Private.h"

@implementation DiscoveryViewController (Contacts)

- (void)prepareContactBackup {
    if (_contactBackup != nil || _selectedDevice == nil) return;
    _contactBackupDevice = [_selectedDevice copy];
    _contactBackup = [[ContactBackup alloc] init];
    _contactBackup.delegate = self;
    [self updateStatusLabel];
    [_contactBackup start];
}

- (void)contactBackupDidFinish:(ContactBackup *)backup {
    if (backup == nil || backup != _contactBackup) return;
    _contactBackupReady = YES;
    if (!_radarScreenVisible || [UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        [self dismissContactBackup];
        return;
    }
    // iOS 6 can finish permission callbacks before the system prompt has fully
    // dismissed. Present our alert once the application becomes active again.
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    if (_contactBackupAlert != nil) return;
    if ([backup.errorMessage length]) {
        UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:@"Contact backup"
            message:backup.errorMessage delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] autorelease];
        [alert show];
        [self dismissContactBackup];
        [self updateStatusLabel];
        return;
    }
    NSString *message = [NSString stringWithFormat:
        @"Send %lu contact%@ to %@ as one .vcf file?",
        (unsigned long)backup.contactCount, backup.contactCount == 1 ? @"" : @"s",
        DisplayNameForReceivePrompt([_contactBackupDevice objectForKey:@"alias"])];
    _contactBackupAlert = [[UIAlertView alloc] initWithTitle:@"Back up contacts?" message:message
        delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Send", nil];
    [_contactBackupAlert show];
}

- (void)dismissContactBackup {
    _contactBackupReady = NO;
    _contactBackupAlert.delegate = nil;
    [_contactBackupAlert dismissWithClickedButtonIndex:_contactBackupAlert.cancelButtonIndex animated:NO];
    [_contactBackupAlert release];
    _contactBackupAlert = nil;
    _contactBackup.delegate = nil;
    [_contactBackup cancel];
    [_contactBackup release];
    _contactBackup = nil;
    [_contactBackupDevice release];
    _contactBackupDevice = nil;
}
@end
