#import "AppDelegate.h"
#import "Discovery.h"
#import "DiscoveryViewController.h"
#import "ReceivedFilesViewController.h"
#import "SettingsViewController.h"

static NSString *const CertificateWarningShownKey = @"LocalSendCertificateWarningShown";

@interface AppDelegate ()
- (void)checkCertificateDate;
- (void)identityChanged:(NSNotification *)notification;
@end

@implementation AppDelegate
@synthesize window = _window;

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];

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
    [self.window makeKeyAndVisible];

    [tabController release];
    [send release];
    [received release];
    [settings release];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(identityChanged:)
                                                 name:DiscoverySetupDidChangeNotification
                                               object:[Discovery sharedDiscovery]];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [[Discovery sharedDiscovery] stop];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [[Discovery sharedDiscovery] start];
    [self checkCertificateDate];
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
    _certificateAlertVisible = NO;
    if (buttonIndex == 1) {
        UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
        tabs.selectedIndex = 2;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_window release];
    [super dealloc];
}
@end
