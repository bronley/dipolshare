#import "LocalSendKeyTestViewController.h"
#import "LocalSendKeyDiagnostics.h"

static NSString *const LocalSendKeyLookupLastReportKey = @"LocalSendKeyLookupLastReport";

@interface LocalSendKeyTestViewController ()
- (void)runAgain:(id)sender;
- (void)runDiagnosticsInBackground:(id)unused;
- (void)diagnosticsFinished:(NSString *)report;
- (void)updateReportView;
- (void)copyReport:(id)sender;
@end

@implementation LocalSendKeyTestViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Key test";
    self.view.backgroundColor = [UIColor whiteColor];

    _reportTextView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _reportTextView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _reportTextView.editable = NO;
    _reportTextView.font = [UIFont fontWithName:@"Courier" size:12.0];
    _reportTextView.textColor = [UIColor blackColor];
    _reportTextView.backgroundColor = [UIColor whiteColor];
    [self.view addSubview:_reportTextView];

    _copyReportButton = [[UIBarButtonItem alloc] initWithTitle:@"Copy report"
                                                         style:UIBarButtonItemStyleBordered
                                                        target:self
                                                        action:@selector(copyReport:)];
    _runAgainButton = [[UIBarButtonItem alloc] initWithTitle:@"Run again"
                                                       style:UIBarButtonItemStyleBordered
                                                      target:self
                                                      action:@selector(runAgain:)];
    UIBarButtonItem *space =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                      target:nil
                                                      action:nil];
    self.toolbarItems = [NSArray arrayWithObjects:_copyReportButton, space, _runAgainButton, nil];
    [space release];
    [self.navigationController setToolbarHidden:NO animated:NO];

    if (_report == nil) {
        _report = [[[NSUserDefaults standardUserDefaults] stringForKey:LocalSendKeyLookupLastReportKey] copy];
    }
    if (!_hasStartedDiagnostics) {
        [self runAgain:nil];
    } else {
        [self updateReportView];
    }
}

- (void)updateReportView {
    _copyReportButton.enabled = !_isRunningDiagnostics && [_report length] > 0;
    _runAgainButton.enabled = !_isRunningDiagnostics;
    self.navigationItem.prompt = _isRunningDiagnostics ? @"Running key checks…" : nil;
    if (_isRunningDiagnostics) {
        _reportTextView.text =
            [_report length] > 0
                ? [NSString stringWithFormat:@"Running a new test…\n\nPrevious report:\n\n%@", _report]
                : @"Running key checks…\n\nThis can take a little time. You can close this screen while the "
                  @"test finishes.";
    } else {
        _reportTextView.text = _report;
    }
}

- (void)runAgain:(id)sender {
    if (_isRunningDiagnostics) {
        return;
    }
    _hasStartedDiagnostics = YES;
    _isRunningDiagnostics = YES;
    [self updateReportView];
    [NSThread detachNewThreadSelector:@selector(runDiagnosticsInBackground:) toTarget:self withObject:nil];
}

- (void)runDiagnosticsInBackground:(id)unused {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *report = nil;
    @try {
        report = [LocalSendKeyDiagnostics runKeyLookupDiagnostics];
        if (![report isKindOfClass:[NSString class]] || [report length] == 0) {
            report = @"The key test did not return a report. Please run it again.";
        }
    } @catch (NSException *exception) {
        // Keep unexpected exception details out of the saved/copied report.
        report = @"The key test could not finish. Please run it again.";
    }
    [self performSelectorOnMainThread:@selector(diagnosticsFinished:) withObject:report waitUntilDone:NO];
    [pool drain];
}

- (void)diagnosticsFinished:(NSString *)report {
    [_report release];
    _report = [report copy];
    _isRunningDiagnostics = NO;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:_report forKey:LocalSendKeyLookupLastReportKey];
    [defaults synchronize];
    [self updateReportView];
    [_reportTextView setContentOffset:CGPointMake(0, 0) animated:NO];
}

- (void)copyReport:(id)sender {
    if (_isRunningDiagnostics || [_report length] == 0) {
        return;
    }
    [UIPasteboard generalPasteboard].string = _report;
    self.navigationItem.prompt = @"Report copied";
}

- (void)viewDidUnload {
    [_reportTextView release];
    _reportTextView = nil;
    [_copyReportButton release];
    _copyReportButton = nil;
    [_runAgainButton release];
    _runAgainButton = nil;
    self.toolbarItems = nil;
    [super viewDidUnload];
}

- (void)dealloc {
    [_reportTextView release];
    [_copyReportButton release];
    [_runAgainButton release];
    [_report release];
    [super dealloc];
}
@end
