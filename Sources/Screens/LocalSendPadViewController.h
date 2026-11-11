#import <UIKit/UIKit.h>

// Two persistent navigation stacks, including on iOS 4 where child containment
// APIs are not available. Settings belongs to the discovery pane.
@interface LocalSendPadViewController : UIViewController {
    UINavigationController *_receivedNavigation;
    UINavigationController *_sendNavigation;
    UIPopoverController *_settingsPopover;
    UIBarButtonItem *_settingsButton;
    UIView *_paneDivider;
}
- (void)showSettings;
@end
