#import "LocalSendPadViewController.h"
#import "DiscoveryViewController.h"
#import "ReceivedFilesViewController.h"
#import "SettingsViewController.h"

@interface LocalSendPadViewController ()
- (void)layoutPanes;
- (NSArray *)paneControllers;
- (void)toggleSettings:(id)sender;
@end

@interface LocalSendPadLayoutView : UIView {
    LocalSendPadViewController *_owner;
}
@property (nonatomic, assign) LocalSendPadViewController *owner;
@end
@implementation LocalSendPadLayoutView
@synthesize owner = _owner;
- (void)layoutSubviews {
    [super layoutSubviews];
    [_owner layoutPanes];
}
@end

@implementation LocalSendPadViewController
- (void)loadView {
    LocalSendPadLayoutView *view = [[LocalSendPadLayoutView alloc]
        initWithFrame:[[UIScreen mainScreen] applicationFrame]];
    view.owner = self;
    view.backgroundColor = [UIColor blackColor];
    self.view = view;
    [view release];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    ReceivedFilesViewController *received =
        [[ReceivedFilesViewController alloc] initWithReceiveActive:NO];
    DiscoveryViewController *send = [[DiscoveryViewController alloc] init];
    send.title = @"Send file";
    _receivedNavigation = [[UINavigationController alloc] initWithRootViewController:received];
    _sendNavigation = [[UINavigationController alloc] initWithRootViewController:send];
    [received release];
    [send release];
    for (UINavigationController *navigation in [self paneControllers]) {
        navigation.navigationBar.barStyle = UIBarStyleBlack;
        if ([self respondsToSelector:@selector(addChildViewController:)]) {
            [self addChildViewController:navigation];
        }
        [self.view addSubview:navigation.view];
        if ([navigation respondsToSelector:@selector(didMoveToParentViewController:)]) {
            [navigation didMoveToParentViewController:self];
        }
    }
    _paneDivider = [[UIView alloc] initWithFrame:CGRectZero];
    _paneDivider.backgroundColor = [UIColor colorWithWhite:0.47f alpha:1.0f];
    _paneDivider.userInteractionEnabled = NO;
    [self.view addSubview:_paneDivider];
    _settingsButton = [[UIBarButtonItem alloc] initWithTitle:@"Settings"
        style:UIBarButtonItemStyleBordered target:self action:@selector(toggleSettings:)];
    send.navigationItem.leftBarButtonItem = _settingsButton;
    [self layoutPanes];
}

- (NSArray *)paneControllers {
    return [NSArray arrayWithObjects:_receivedNavigation, _sendNavigation, nil];
}

- (void)layoutPanes {
    CGRect bounds = self.view.bounds;
    _receivedNavigation.view.frame = CGRectMake(0, 0, 300, bounds.size.height);
    _sendNavigation.view.frame = CGRectMake(300, 0, bounds.size.width - 300, bounds.size.height);
    CGRect barFrame = [_receivedNavigation.navigationBar
        convertRect:_receivedNavigation.navigationBar.bounds toView:self.view];
    CGFloat dividerTop = CGRectGetMaxY(barFrame);
    _paneDivider.frame = CGRectMake(299, dividerTop, 1, MAX(0, bounds.size.height - dividerTop));
    DiscoveryViewController *send = [[_sendNavigation viewControllers] objectAtIndex:0];
    [send layoutForContainer];
}

- (BOOL)automaticallyForwardAppearanceAndRotationMethodsToChildViewControllers { return NO; }
- (BOOL)shouldAutomaticallyForwardAppearanceMethods { return NO; }
- (BOOL)shouldAutomaticallyForwardRotationMethods { return NO; }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    for (UIViewController *pane in [self paneControllers]) [pane viewWillAppear:animated];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    for (UIViewController *pane in [self paneControllers]) [pane viewDidAppear:animated];
}
- (void)viewWillDisappear:(BOOL)animated {
    [_settingsPopover dismissPopoverAnimated:NO];
    for (UIViewController *pane in [self paneControllers]) [pane viewWillDisappear:animated];
    [super viewWillDisappear:animated];
}
- (void)viewDidDisappear:(BOOL)animated {
    for (UIViewController *pane in [self paneControllers]) [pane viewDidDisappear:animated];
    [super viewDidDisappear:animated];
}
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation { return YES; }
- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration {
    [_settingsPopover dismissPopoverAnimated:NO];
    for (UIViewController *pane in [self paneControllers])
        [pane willRotateToInterfaceOrientation:orientation duration:duration];
}
- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration {
    [self layoutPanes];
    for (UIViewController *pane in [self paneControllers])
        [pane willAnimateRotationToInterfaceOrientation:orientation duration:duration];
}
- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)orientation {
    for (UIViewController *pane in [self paneControllers]) [pane didRotateFromInterfaceOrientation:orientation];
    [self layoutPanes];
}

- (void)toggleSettings:(id)sender {
    if (_settingsPopover.popoverVisible) {
        [_settingsPopover dismissPopoverAnimated:YES];
    } else {
        [self showSettings];
    }
}
- (void)showSettings {
    [_settingsPopover dismissPopoverAnimated:NO];
    [_settingsPopover release];
    SettingsViewController *settings = [[SettingsViewController alloc] init];
    settings.contentSizeForViewInPopover = CGSizeMake(320, 500);
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:settings];
    navigation.navigationBar.barStyle = UIBarStyleBlack;
    navigation.contentSizeForViewInPopover = CGSizeMake(320, 544);
    _settingsPopover = [[UIPopoverController alloc] initWithContentViewController:navigation];
    _settingsPopover.popoverContentSize = CGSizeMake(320, 544);
    [_settingsPopover presentPopoverFromBarButtonItem:_settingsButton
        permittedArrowDirections:UIPopoverArrowDirectionUp animated:YES];
    [navigation release];
    [settings release];
}
#if DIPOLSHARE_DEV_TESTING
- (void)dismissSettingsForScreenshot {
    [_settingsPopover dismissPopoverAnimated:NO];
}
#endif
- (void)viewDidUnload {
    [_settingsPopover dismissPopoverAnimated:NO];
    [_settingsPopover release]; _settingsPopover = nil;
    for (UIViewController *pane in [self paneControllers]) {
        if ([pane respondsToSelector:@selector(removeFromParentViewController)]) {
            [pane willMoveToParentViewController:nil];
            [pane removeFromParentViewController];
        }
    }
    [_receivedNavigation release]; _receivedNavigation = nil;
    [_sendNavigation release]; _sendNavigation = nil;
    [_settingsButton release]; _settingsButton = nil;
    [_paneDivider release]; _paneDivider = nil;
    [super viewDidUnload];
}
- (void)dealloc {
    if ([self isViewLoaded]) ((LocalSendPadLayoutView *)self.view).owner = nil;
    [_settingsPopover dismissPopoverAnimated:NO];
    [_settingsPopover release];
    [_settingsButton release];
    [_paneDivider release];
    [_receivedNavigation release];
    [_sendNavigation release];
    [super dealloc];
}
@end
