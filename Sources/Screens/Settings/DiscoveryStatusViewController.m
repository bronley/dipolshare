#import "DiscoveryStatusViewController.h"
#import "Discovery.h"

@interface DiscoveryStatusViewController ()
- (void)updateReport;
- (void)copyReport;
@end

@implementation DiscoveryStatusViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Discovery status";
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithTitle:@"Copy" style:UIBarButtonItemStylePlain target:self action:@selector(copyReport)] autorelease];
    CGRect bounds = self.view.bounds;
    _reportView = [[UITextView alloc] initWithFrame:CGRectMake(0, 0, bounds.size.width, bounds.size.height - 44)];
    _reportView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _reportView.editable = NO;
    _reportView.font = [UIFont systemFontOfSize:13];
    [self.view addSubview:_reportView];
    UIToolbar *toolbar = [[[UIToolbar alloc] initWithFrame:
        CGRectMake(0, bounds.size.height - 44, bounds.size.width, 44)] autorelease];
    toolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    toolbar.items = [NSArray arrayWithObject:[[[UIBarButtonItem alloc]
        initWithTitle:@"Update report" style:UIBarButtonItemStylePlain
        target:self action:@selector(updateReport)] autorelease]];
    [self.view addSubview:toolbar];
    [self updateReport];
}
- (void)updateReport {
    _reportView.text = [[Discovery sharedDiscovery] discoveryDiagnostics];
}
- (void)copyReport {
    [UIPasteboard generalPasteboard].string = _reportView.text;
}
- (void)viewDidUnload {
    [_reportView release];
    _reportView = nil;
    [super viewDidUnload];
}
- (void)dealloc {
    [_reportView release];
    [super dealloc];
}
@end
