#import <UIKit/UIKit.h>

@interface LocalSendPhotoPreviewViewController : UIViewController <UIScrollViewDelegate, UINavigationBarDelegate> {
    UINavigationBar *_navigationBar;
    UIImage *_image;
    NSURL *_fileURL;
    NSOperationQueue *_imageLoadQueue;
    UIActivityIndicatorView *_loadingIndicator;
    UILabel *_errorLabel;
    BOOL _loadStarted;
    BOOL _loadFinished;
    BOOL _closed;
    UIScrollView *_scrollView;
    UIImageView *_imageView;
    CGSize _lastViewportSize;
    id _actionTarget;
    SEL _actionSelector;
    UIBarButtonItem *_shareButton;
}
@property (nonatomic, readonly) UIBarButtonItem *shareButton;
- (id)initWithFileURL:(NSURL *)fileURL title:(NSString *)title target:(id)target action:(SEL)action;
@end
