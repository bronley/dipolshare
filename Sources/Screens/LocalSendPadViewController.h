#import <UIKit/UIKit.h>

@interface LocalSendPadViewController : UIViewController {
    UINavigationController *_receivedNavigation;
    UINavigationController *_sendNavigation;
    UIPopoverController *_settingsPopover;
    UIBarButtonItem *_settingsButton;
    UIView *_paneDivider;
}
- (void)showSettings;
@end
