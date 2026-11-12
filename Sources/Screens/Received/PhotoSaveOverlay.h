#import <UIKit/UIKit.h>

@interface PhotoSaveOverlay : UIView {
    UIView *_panel;
    UILabel *_label;
    UIActivityIndicatorView *_activityIndicator;
}
- (void)setCompletedPhotos:(NSUInteger)completed total:(NSUInteger)total;
@end
