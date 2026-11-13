#import "AppDelegate.h"
#import "Discovery.h"
#import "DiscoveryViewController.h"
#import "ReceivedFilesViewController.h"
#import "SettingsViewController.h"
#import "LocalSendPadViewController.h"
#import "Receiver.h"
#import "Transfer.h"

static NSString *const CertificateWarningShownKey = @"LocalSendCertificateWarningShown";

@interface AppDelegate ()
- (void)checkCertificateDate;
- (void)identityChanged:(NSNotification *)notification;
- (void)showPendingUpdate;
- (void)transferActivityChanged:(NSNotification *)notification;
@end

@implementation AppDelegate
@synthesize window = _window;

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];

    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        LocalSendPadViewController *pad = [[LocalSendPadViewController alloc] init];
        self.window.rootViewController = pad;
        [pad release];
    } else {
        DiscoveryViewController *send = [[DiscoveryViewController alloc] init];
        ReceivedFilesViewController *received =
            [[ReceivedFilesViewController alloc] initWithReceiveStatus:nil active:NO];
        SettingsViewController *settings = [[SettingsViewController alloc] init];

        NSArray *screens = [NSArray arrayWithObjects:send, received, settings, nil];
        NSArray *titles = [NSArray arrayWithObjects:@"Send file", @"Received", @"Settings", nil];
        NSArray *icons = [NSArray arrayWithObjects:@"Send file active", @"Received active",
                                                   @"Settings active", nil];
        NSMutableArray *tabs = [NSMutableArray arrayWithCapacity:[screens count]];
        for (NSUInteger index = 0; index < [screens count]; index++) {
            UIViewController *screen = [screens objectAtIndex:index];
            UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:screen];
            navigation.navigationBar.barStyle = UIBarStyleBlack;
            navigation.tabBarItem = [[[UITabBarItem alloc] initWithTitle:[titles objectAtIndex:index]
                                                                  image:[UIImage imageNamed:[icons objectAtIndex:index]]
                                                                    tag:index] autorelease];
            [tabs addObject:navigation];
            if (screen == received) {
                [received refreshBadge];
            }
            [navigation release];
        }

        UITabBarController *tabController = [[UITabBarController alloc] init];
        tabController.viewControllers = tabs;
        self.window.rootViewController = tabController;


        [tabController release];
        [send release];
        [received release];
        [settings release];
    }
    [self.window makeKeyAndVisible];
    NSBundle *bundle = [NSBundle mainBundle];
    _updateChecker = [[UpdateChecker alloc] initWithURL:[NSURL URLWithString:[bundle objectForInfoDictionaryKey:@"DipolShareUpdateManifestURL"]]
        installedVersion:[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
        systemVersion:[[UIDevice currentDevice] systemVersion] defaults:[NSUserDefaults standardUserDefaults]];
    _updateChecker.delegate = self;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(transferActivityChanged:)
        name:TransferDidUpdateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(transferActivityChanged:)
        name:ReceiveProgressNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(identityChanged:)
                                                 name:DiscoverySetupDidChangeNotification
                                               object:[Discovery sharedDiscovery]];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [_updateChecker cancel];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showPendingUpdate) object:nil];
    [_pendingUpdateVersion release];
    _pendingUpdateVersion = nil;
    _updateAlert.delegate = nil;
    [_updateAlert dismissWithClickedButtonIndex:0 animated:NO];
    [_updateAlert release];
    _updateAlert = nil;
    [[Discovery sharedDiscovery] stop];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [[Discovery sharedDiscovery] start];
    [self checkCertificateDate];
    [_updateChecker check];
    [self showPendingUpdate];
}

- (void)identityChanged:(NSNotification *)notification {
    [self checkCertificateDate];
}

- (void)checkCertificateDate {
    if (_certificateAlertVisible || [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        return;
    }
    Discovery *discovery = [Discovery sharedDiscovery];
    CertificateDateStatus status = [discovery certificateDateStatus];
    if (status != CertificateDateStatusExpired &&
        status != CertificateDateStatusNotYetValid &&
        status != CertificateDateStatusClockIncorrect) {
        return;
    }
    NSString *fingerprint = [discovery identityFingerprint];
    if (fingerprint == nil) {
        return;
    }
    NSString *warningID = [NSString stringWithFormat:@"%@:%d", fingerprint, (int)status];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([[defaults stringForKey:CertificateWarningShownKey] isEqualToString:warningID]) {
        return;
    }
    [defaults setObject:warningID forKey:CertificateWarningShownKey];
    [defaults synchronize];
    NSString *message = status == CertificateDateStatusClockIncorrect
        ? @"This device's date looks too far in the past. Set the correct date and time, then regenerate the device key in Settings so secure transfers work."
        : @"This device's certificate is outside its valid dates. Check the device clock, then regenerate the device key in Settings so secure transfers work.";
    _certificateAlertVisible = YES;
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:@"Hey, time traveller!"
                                                   message:message
                                                  delegate:self
                                         cancelButtonTitle:@"Later"
                                         otherButtonTitles:@"Open Settings", nil] autorelease];
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView == _updateAlert) {
        if (buttonIndex == 0) [_updateChecker dismissVersion:_pendingUpdateVersion];
        else [_updateChecker remindLaterForVersion:_pendingUpdateVersion];
        [_pendingUpdateVersion release];
        _pendingUpdateVersion = nil;
        _updateAlert.delegate = nil;
        [_updateAlert release];
        _updateAlert = nil;
        return;
    }
    _certificateAlertVisible = NO;
    if (buttonIndex == 1) {
        if ([self.window.rootViewController isKindOfClass:[LocalSendPadViewController class]]) {
            [(LocalSendPadViewController *)self.window.rootViewController showSettings];
            return;
        }
        UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
        tabs.selectedIndex = 2;
    }
}

- (void)transferActivityChanged:(NSNotification *)notification {
    if ([[notification name] isEqualToString:TransferDidUpdateNotification]) {
        _sendingFiles = [[[notification userInfo] objectForKey:@"isActive"] boolValue];
    } else {
        _receivingFiles = [[[notification userInfo] objectForKey:@"active"] boolValue];
    }
}

- (void)updateChecker:(UpdateChecker *)checker foundVersion:(NSString *)version {
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive || _updateAlert != nil) return;
    [_pendingUpdateVersion release];
    _pendingUpdateVersion = [version copy];
    [self showPendingUpdate];
}

- (void)showPendingUpdate {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showPendingUpdate) object:nil];
    if (_pendingUpdateVersion == nil || _updateAlert != nil ||
        [UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    BOOL blocked = _certificateAlertVisible || _sendingFiles || _receivingFiles ||
        [[Receiver sharedReceiver] pendingRequest] != nil ||
        [UIApplication sharedApplication].keyWindow != _window ||
        _window.rootViewController.modalViewController != nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (!window.hidden && window.windowLevel > UIWindowLevelNormal) blocked = YES;
    }
    if (blocked) {
        [self performSelector:@selector(showPendingUpdate) withObject:nil afterDelay:5.0];
        return;
    }
    NSString *installed = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *message = [NSString stringWithFormat:@"DipolShare %@ is available.\n\nCurrent version is %@.", _pendingUpdateVersion, installed];
    _updateAlert = [[UIAlertView alloc] initWithTitle:@"New Version Available" message:message delegate:self
        cancelButtonTitle:@"Dismiss" otherButtonTitles:@"Remind Later", nil];
    [_updateAlert show];
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    _updateChecker.delegate = nil;
    [_updateChecker release];
    _updateAlert.delegate = nil;
    [_updateAlert dismissWithClickedButtonIndex:0 animated:NO];
    [_updateAlert release];
    [_pendingUpdateVersion release];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_window release];
    [super dealloc];
}
@end
