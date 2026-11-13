#import <UIKit/UIKit.h>
#import "UpdateChecker.h"

@interface AppDelegate : NSObject <UIApplicationDelegate, UIAlertViewDelegate, UpdateCheckerDelegate> {
    UIWindow *_window;
    BOOL _certificateAlertVisible;
    UpdateChecker *_updateChecker;
    NSString *_pendingUpdateVersion;
    UIAlertView *_updateAlert;
    BOOL _sendingFiles;
    BOOL _receivingFiles;
}
@property (nonatomic, retain) UIWindow *window;
@end
