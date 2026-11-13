#import "LocalSendPhotoPreviewViewController.h"
#import <ImageIO/ImageIO.h>

@interface LocalSendPhotoPreviewViewController ()
- (void)configureNavigationBar;
- (void)layoutPreview;
- (void)layoutPhoto;
- (void)startLoadingPhoto;
- (void)loadPhotoInBackground;
- (CGImageRef)copyPhotoThumbnail;
- (UIImage *)decodedImageFromThumbnail:(CGImageRef)thumbnail;
- (void)photoDidLoad:(UIImage *)image;
- (void)updateLoadingStatus;
- (void)centerPhoto;
- (void)share:(id)sender;
- (void)close:(id)sender;
@end

@implementation LocalSendPhotoPreviewViewController
@synthesize shareButton = _shareButton;
- (id)initWithFileURL:(NSURL *)fileURL title:(NSString *)title target:(id)target action:(SEL)action {
    self = [super init];
    if (self) {
        _fileURL = [fileURL retain];
        self.title = title;
        _actionTarget = target;
        _actionSelector = action;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.17f alpha:1.0f];
    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.delegate = self;
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:_scrollView];
    _imageView = [[UIImageView alloc] initWithImage:_image];
    [_scrollView addSubview:_imageView];
    _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _loadingIndicator.hidesWhenStopped = YES;
    _loadingIndicator.accessibilityLabel = @"Loading photo";
    [self.view addSubview:_loadingIndicator];
    _errorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _errorLabel.backgroundColor = [UIColor clearColor];
    _errorLabel.textColor = [UIColor whiteColor];
    _errorLabel.text = @"This photo could not be opened.";
    _errorLabel.textAlignment = UITextAlignmentCenter;
    _errorLabel.font = [UIFont systemFontOfSize:15];
    _errorLabel.numberOfLines = 2;
    [self.view addSubview:_errorLabel];
    _shareButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
        target:self action:@selector(share:)];
    _shareButton.accessibilityLabel = @"Share photo";
    self.navigationItem.rightBarButtonItem = _shareButton;
    [self configureNavigationBar];
    [self layoutPreview];
    [self updateLoadingStatus];
}

- (void)configureNavigationBar {
    _navigationBar = [[UINavigationBar alloc] initWithFrame:CGRectZero];
    _navigationBar.barStyle = UIBarStyleBlack;
    _navigationBar.translucent = NO;
    _navigationBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UINavigationItem *receivedItem = [[[UINavigationItem alloc] initWithTitle:@"Received"] autorelease];
    receivedItem.backBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Back"
        style:UIBarButtonItemStyleBordered target:nil action:NULL] autorelease];
    [_navigationBar setItems:[NSArray arrayWithObjects:receivedItem, self.navigationItem, nil] animated:NO];
    _navigationBar.delegate = self;
    [self.view addSubview:_navigationBar];
}

- (BOOL)navigationBar:(UINavigationBar *)navigationBar shouldPopItem:(UINavigationItem *)item {
    if (navigationBar == _navigationBar && item == self.navigationItem && !_closed) {
        [self close:nil];
    }
    return NO;
}

- (void)layoutPreview {
    CGRect bounds = self.view.bounds;
    CGFloat barHeight = [_navigationBar sizeThatFits:bounds.size].height;
    _navigationBar.frame = CGRectMake(CGRectGetMinX(bounds), CGRectGetMinY(bounds), bounds.size.width, barHeight);
    _scrollView.frame = CGRectMake(CGRectGetMinX(bounds), CGRectGetMinY(bounds) + barHeight,
        bounds.size.width, MAX(0, bounds.size.height - barHeight));
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self layoutPreview];
    [self startLoadingPhoto];
    [self updateLoadingStatus];
    [self layoutPhoto];
}

- (void)startLoadingPhoto {
    if (_loadStarted || _closed) return;
    _loadStarted = YES;
    _imageLoadQueue = [[NSOperationQueue alloc] init];
    [_imageLoadQueue setMaxConcurrentOperationCount:1];
    NSInvocationOperation *operation = [[NSInvocationOperation alloc]
        initWithTarget:self selector:@selector(loadPhotoInBackground) object:nil];
    [_imageLoadQueue addOperation:operation];
    [operation release];
}

- (void)loadPhotoInBackground {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    CGImageRef thumbnail = [self copyPhotoThumbnail];
    UIImage *image = thumbnail == NULL ? nil : [self decodedImageFromThumbnail:thumbnail];
    if (thumbnail != NULL) CGImageRelease(thumbnail);
    [self performSelectorOnMainThread:@selector(photoDidLoad:) withObject:image waitUntilDone:NO];
    [pool drain];
}

- (CGImageRef)copyPhotoThumbnail {
    NSDictionary *sourceOptions = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:NO]
        forKey:(NSString *)kCGImageSourceShouldCache];
    CGImageSourceRef source = CGImageSourceCreateWithURL((CFURLRef)_fileURL, (CFDictionaryRef)sourceOptions);
    if (source == NULL) return NULL;
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:YES], (NSString *)kCGImageSourceCreateThumbnailFromImageAlways,
        [NSNumber numberWithBool:YES], (NSString *)kCGImageSourceCreateThumbnailWithTransform,
        [NSNumber numberWithInt:2048], (NSString *)kCGImageSourceThumbnailMaxPixelSize, nil];
    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (CFDictionaryRef)options);
    CFRelease(source);
    return thumbnail;
}

- (UIImage *)decodedImageFromThumbnail:(CGImageRef)thumbnail {
    size_t width = CGImageGetWidth(thumbnail), height = CGImageGetHeight(thumbnail);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (bitmap == NULL) return nil;
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), thumbnail);
    CGImageRef decoded = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    if (decoded == NULL) return nil;
    UIImage *image = [UIImage imageWithCGImage:decoded];
    CGImageRelease(decoded);
    return image;
}

- (void)photoDidLoad:(UIImage *)image {
    if (_closed) return;
    _loadFinished = YES;
    [_image release];
    _image = [image retain];
    _imageView.image = _image;
    _lastViewportSize = CGSizeZero;
    if ([self isViewLoaded]) {
        [self updateLoadingStatus];
        [self layoutPhoto];
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, _errorLabel.hidden ? nil : _errorLabel);
    }
}

- (void)updateLoadingStatus {
    CGSize size = self.view.bounds.size;
    self.view.backgroundColor = _image != nil ? [UIColor blackColor] : [UIColor colorWithWhite:0.17f alpha:1.0f];
    UIWindow *window = self.view.window;
    CGPoint spinnerCenter = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
    if (window != nil) {
        CGPoint screenCenter = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
        spinnerCenter = [self.view convertPoint:screenCenter fromView:window];
    }
    _loadingIndicator.center = spinnerCenter;
    _errorLabel.frame = CGRectMake(20, size.height / 2 - 25, MAX(0, size.width - 40), 50);
    _errorLabel.hidden = !_loadFinished || _image != nil;
    _shareButton.enabled = _image != nil;
    if (_loadFinished) [_loadingIndicator stopAnimating];
    else [_loadingIndicator startAnimating];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutPreview];
    [self updateLoadingStatus];
    [self layoutPhoto];
}
- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)orientation {
    [super didRotateFromInterfaceOrientation:orientation];
    [self layoutPreview];
    [self updateLoadingStatus];
    [self layoutPhoto];
}
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad || orientation == UIInterfaceOrientationPortrait;
}
- (void)layoutPhoto {
    if (_image == nil) return;
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
- (void)share:(id)sender {
    if (!_closed && _image != nil) [_actionTarget performSelector:_actionSelector withObject:self];
}
- (void)close:(id)sender {
    _closed = YES;
    [_imageLoadQueue cancelAllOperations];
    [self dismissModalViewControllerAnimated:YES];
}
- (void)viewDidUnload {
    _navigationBar.delegate = nil;
    [_navigationBar release]; _navigationBar = nil;
    _scrollView.delegate = nil;
    [_scrollView release]; _scrollView = nil;
    [_imageView release]; _imageView = nil;
    [_shareButton release]; _shareButton = nil;
    [_loadingIndicator release]; _loadingIndicator = nil;
    [_errorLabel release]; _errorLabel = nil;
    _lastViewportSize = CGSizeZero;
    [super viewDidUnload];
}
- (void)dealloc {
    _navigationBar.delegate = nil;
    [_navigationBar release];
    _scrollView.delegate = nil;
    [_scrollView release];
    [_imageView release];
    [_image release];
    [_fileURL release];
    [_imageLoadQueue cancelAllOperations];
    [_imageLoadQueue release];
    [_loadingIndicator release];
    [_errorLabel release];
    [_shareButton release];
    [super dealloc];
}
@end
