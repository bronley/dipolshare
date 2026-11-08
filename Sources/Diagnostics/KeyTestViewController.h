#import <UIKit/UIKit.h>

@interface KeyTestViewController : UIViewController {
    UITextView *_reportTextView;
    UIBarButtonItem *_copyReportButton;
    UIBarButtonItem *_runAgainButton;
    NSString *_report;
    BOOL _isRunningDiagnostics;
    BOOL _hasStartedDiagnostics;
}
@end
