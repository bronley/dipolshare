#import "SplashScreenshotViewController.h"

#if DIPOLSHARE_DEV_TESTING
#import "RadarBackgroundView.h"

@interface SplashScreenshotLayoutView : UIView {
    RadarBackgroundView *_background;
    UINavigationBar *_navigationBar;
    UITabBar *_tabBar;
    UIView *_sidebar;
    UIView *_divider;
}
@end

@implementation SplashScreenshotLayoutView
- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor blackColor];
        _background = [[RadarBackgroundView alloc] initWithFrame:CGRectZero];
        _background.contentMode = UIViewContentModeRedraw;
        [self addSubview:_background];
        _navigationBar = [[UINavigationBar alloc] initWithFrame:CGRectZero];
        _navigationBar.barStyle = UIBarStyleBlack;
        _navigationBar.translucent = NO;
        _navigationBar.userInteractionEnabled = NO;
        [self addSubview:_navigationBar];
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
            _sidebar = [[UIView alloc] initWithFrame:CGRectZero];
            _sidebar.backgroundColor = [UIColor whiteColor];
            [self addSubview:_sidebar];
            _divider = [[UIView alloc] initWithFrame:CGRectZero];
            _divider.backgroundColor = [UIColor colorWithWhite:0.47f alpha:1.0f];
            [self addSubview:_divider];
        } else {
            _tabBar = [[UITabBar alloc] initWithFrame:CGRectZero];
            _tabBar.userInteractionEnabled = NO;
            [self addSubview:_tabBar];
        }
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    CGFloat statusBarHeight = 20;
    CGFloat navigationHeight = [_navigationBar sizeThatFits:size].height;
    CGFloat tabHeight = _tabBar != nil ? [_tabBar sizeThatFits:size].height : 0;
    CGFloat contentTop = statusBarHeight + navigationHeight;
    CGFloat contentHeight = MAX(0, size.height - contentTop - tabHeight);
    CGFloat sidebarWidth = _sidebar != nil ? 300 : 0;
    _navigationBar.frame = CGRectMake(0, statusBarHeight, size.width, navigationHeight);
    _background.frame = CGRectMake(sidebarWidth, contentTop, size.width - sidebarWidth, contentHeight);
    _sidebar.frame = CGRectMake(0, contentTop, sidebarWidth, contentHeight);
    _divider.frame = CGRectMake(sidebarWidth - 1, contentTop, 1, contentHeight);
    _tabBar.frame = CGRectMake(0, size.height - tabHeight, size.width, tabHeight);
}

- (void)dealloc {
    [_background release];
    [_navigationBar release];
    [_tabBar release];
    [_sidebar release];
    [_divider release];
    [super dealloc];
}
@end

@implementation SplashScreenshotViewController
- (void)loadView {
    self.wantsFullScreenLayout = YES;
    self.view = [[[SplashScreenshotLayoutView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    UITapGestureRecognizer *tap = [[[UITapGestureRecognizer alloc] initWithTarget:self
        action:@selector(closeScreenshot:)] autorelease];
    [self.view addGestureRecognizer:tap];
    self.view.isAccessibilityElement = YES;
    self.view.accessibilityLabel = @"Splash screenshot";
    self.view.accessibilityHint = @"Double-tap to return to the app.";
    self.view.accessibilityTraits = UIAccessibilityTraitButton;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _previousStatusBarHidden = [UIApplication sharedApplication].statusBarHidden;
    [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationNone];
}

- (void)viewWillDisappear:(BOOL)animated {
    [[UIApplication sharedApplication] setStatusBarHidden:_previousStatusBarHidden withAnimation:UIStatusBarAnimationNone];
    [super viewWillDisappear:animated];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad || orientation == UIInterfaceOrientationPortrait;
}

- (void)closeScreenshot:(id)sender {
    [self dismissModalViewControllerAnimated:NO];
}
@end
#endif
