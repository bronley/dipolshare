#import <UIKit/UIKit.h>

@interface LocalSendPhotoPreviewViewController : UIViewController <UIScrollViewDelegate> {
    UIImage *_image;
    UIScrollView *_scrollView;
    UIImageView *_imageView;
    CGSize _lastViewportSize;
    id _actionTarget;
    SEL _actionSelector;
    UIBarButtonItem *_shareButton;
}
@property (nonatomic, readonly) UIBarButtonItem *shareButton;
- (id)initWithImage:(UIImage *)image title:(NSString *)title target:(id)target action:(SEL)action;
@end
