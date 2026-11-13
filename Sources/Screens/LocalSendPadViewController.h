#import <UIKit/UIKit.h>

@interface LocalSendPadViewController : UIViewController {
    UINavigationController *_receivedNavigation;
    UINavigationController *_sendNavigation;
    UIPopoverController *_settingsPopover;
    UIBarButtonItem *_settingsButton;
    UIView *_paneDivider;
}
- (void)showSettings;
#if DIPOLSHARE_DEV_TESTING
- (void)dismissSettingsForScreenshot;
#endif
@end
