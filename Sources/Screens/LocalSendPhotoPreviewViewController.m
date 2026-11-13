#import "LocalSendPhotoPreviewViewController.h"

@interface LocalSendPhotoPreviewViewController ()
- (void)layoutPhoto;
- (void)centerPhoto;
- (void)share:(id)sender;
- (void)close:(id)sender;
@end

@implementation LocalSendPhotoPreviewViewController
@synthesize shareButton = _shareButton;
- (id)initWithImage:(UIImage *)image title:(NSString *)title target:(id)target action:(SEL)action {
    self = [super init];
    if (self) {
        _image = [image retain];
        self.title = title;
        _actionTarget = target;
        _actionSelector = action;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.delegate = self;
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:_scrollView];
    _imageView = [[UIImageView alloc] initWithImage:_image];
    [_scrollView addSubview:_imageView];
    self.navigationItem.leftBarButtonItem = [[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close:)] autorelease];
    _shareButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
        target:self action:@selector(share:)];
    _shareButton.accessibilityLabel = @"Share photo";
    self.navigationItem.rightBarButtonItem = _shareButton;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self layoutPhoto];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutPhoto];
}
- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)orientation {
    [super didRotateFromInterfaceOrientation:orientation];
    [self layoutPhoto];
}
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad || orientation == UIInterfaceOrientationPortrait;
}
- (void)layoutPhoto {
    CGSize viewport = _scrollView.bounds.size;
    if (viewport.width <= 0 || viewport.height <= 0 || CGSizeEqualToSize(viewport, _lastViewportSize)) return;
    _lastViewportSize = viewport;
    _scrollView.minimumZoomScale = 1;
    _scrollView.maximumZoomScale = 1;
    _scrollView.zoomScale = 1;
    _imageView.frame = CGRectMake(0, 0, _image.size.width, _image.size.height);
    _scrollView.contentSize = _image.size;
    CGFloat fit = MIN(viewport.width / _image.size.width, viewport.height / _image.size.height);
    _scrollView.minimumZoomScale = MIN(fit, 1);
    _scrollView.maximumZoomScale = MAX(1, fit * 4);
    _scrollView.zoomScale = MIN(fit, 1);
    [self centerPhoto];
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView { return _imageView; }
- (void)scrollViewDidZoom:(UIScrollView *)scrollView { [self centerPhoto]; }
- (void)centerPhoto {
    _imageView.center = CGPointMake(MAX(_scrollView.contentSize.width, _scrollView.bounds.size.width) / 2,
                                   MAX(_scrollView.contentSize.height, _scrollView.bounds.size.height) / 2);
}
- (void)share:(id)sender { [_actionTarget performSelector:_actionSelector withObject:self]; }
- (void)close:(id)sender { [self dismissModalViewControllerAnimated:YES]; }
- (void)viewDidUnload {
    _scrollView.delegate = nil;
    [_scrollView release]; _scrollView = nil;
    [_imageView release]; _imageView = nil;
    [_shareButton release]; _shareButton = nil;
    _lastViewportSize = CGSizeZero;
    [super viewDidUnload];
}
- (void)dealloc {
    _scrollView.delegate = nil;
    [_scrollView release];
    [_imageView release];
    [_image release];
    [_shareButton release];
    [super dealloc];
}
@end
