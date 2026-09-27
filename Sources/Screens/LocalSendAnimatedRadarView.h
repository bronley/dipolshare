#import <UIKit/UIKit.h>

@interface LocalSendAnimatedRadarView : UIView {
    UIImageView *_sweepView;
    UIImageView *_goldLeftBlipView;
    UIImageView *_goldRightBlipView;
    UIImageView *_whiteBlipView;
    BOOL _animating;
}

- (void)startAnimating;
- (void)stopAnimating;

@end
