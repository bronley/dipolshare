#import <UIKit/UIKit.h>

@interface AppDelegate : NSObject <UIApplicationDelegate, UIAlertViewDelegate> {
    UIWindow *_window;
    BOOL _certificateAlertVisible;
}
@property (nonatomic, retain) UIWindow *window;
@end
