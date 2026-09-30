#import "LocalSendAnimatedRadarView.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static const CGFloat LocalSendRadarFaceVerticalOffset = -4.0f;

#if __ARM_ARCH != 6
static void LocalSendAddBriefBlip(CALayer *layer, CGFloat maximum, CFTimeInterval duration,
                                  CFTimeInterval delay) {
    layer.opacity = 0.035f;
    CAKeyframeAnimation *blink = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    blink.values = [NSArray arrayWithObjects:[NSNumber numberWithFloat:0.035f],
                                             [NSNumber numberWithFloat:0.035f],
                                             [NSNumber numberWithFloat:maximum],
                                             [NSNumber numberWithFloat:0.035f],
                                             [NSNumber numberWithFloat:0.035f], nil];
    blink.keyTimes = [NSArray arrayWithObjects:[NSNumber numberWithFloat:0.0f],
                                               [NSNumber numberWithFloat:0.70f],
                                               [NSNumber numberWithFloat:0.78f],
                                               [NSNumber numberWithFloat:0.88f],
                                               [NSNumber numberWithFloat:1.0f], nil];
    blink.duration = duration;
    blink.beginTime = CACurrentMediaTime() + delay;
    blink.repeatCount = HUGE_VALF;
    [layer addAnimation:blink forKey:@"briefBlip"];
}
#endif

static void LocalSendAddRotation(CALayer *layer, CFTimeInterval duration, CGFloat direction,
                                 NSString *name) {
    CABasicAnimation *rotation = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    rotation.fromValue = [NSNumber numberWithFloat:0.0f];
    rotation.toValue = [NSNumber numberWithFloat:(CGFloat)(M_PI * 2.0) * direction];
    rotation.duration = duration;
    rotation.repeatCount = HUGE_VALF;
    rotation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [layer addAnimation:rotation forKey:name];
}

@interface LocalSendAnimatedRadarView ()
- (UIImageView *)addImageNamed:(NSString *)name centeredAt:(CGPoint)center;
@end

@implementation LocalSendAnimatedRadarView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;

        CGPoint canvasCenter = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
        CGPoint radarFaceCenter =
            CGPointMake(canvasCenter.x, canvasCenter.y + LocalSendRadarFaceVerticalOffset);
        [self addImageNamed:@"Radar base" centeredAt:canvasCenter];
        _sweepView = [self addImageNamed:@"Radar sweep" centeredAt:radarFaceCenter];
        _goldLeftBlipView = [self addImageNamed:@"Blip gold left" centeredAt:radarFaceCenter];
        _goldRightBlipView = [self addImageNamed:@"Blip gold right" centeredAt:radarFaceCenter];
        _whiteBlipView = [self addImageNamed:@"Blip white" centeredAt:radarFaceCenter];
        [self addImageNamed:@"Shadow horizon" centeredAt:radarFaceCenter];
        [self addImageNamed:@"Glint center" centeredAt:radarFaceCenter];
        _goldLeftBlipView.layer.opacity = 0.035f;
        _goldRightBlipView.layer.opacity = 0.035f;
        _whiteBlipView.layer.opacity = 0.035f;
    }
    return self;
}

- (UIImageView *)addImageNamed:(NSString *)name centeredAt:(CGPoint)center {
    UIImageView *imageView = [[[UIImageView alloc] initWithImage:[UIImage imageNamed:name]] autorelease];
    imageView.center = center;
    [self addSubview:imageView];
    return imageView;
}

- (void)startAnimating {
    if (_animating && [_sweepView.layer animationForKey:@"radarRotation"] != nil) {
        return;
    }
    _animating = YES;

    LocalSendAddRotation(_sweepView.layer, 15.0, 1.0f, @"radarRotation");
#if __ARM_ARCH != 6
    LocalSendAddRotation(_goldLeftBlipView.layer, 16.0, 1.0f, @"goldOrbit");
    LocalSendAddRotation(_goldRightBlipView.layer, 18.5, -1.0f, @"goldOrbit");

    LocalSendAddBriefBlip(_goldRightBlipView.layer, 1.0f, 2.55, 0.25);
    LocalSendAddBriefBlip(_whiteBlipView.layer, 0.92f, 3.05, 0.95);
    LocalSendAddBriefBlip(_goldLeftBlipView.layer, 1.0f, 2.8, 1.65);
#endif
}

- (void)stopAnimating {
    if (!_animating) {
        return;
    }
    _animating = NO;
    [_sweepView.layer removeAllAnimations];
    [_goldLeftBlipView.layer removeAllAnimations];
    [_goldRightBlipView.layer removeAllAnimations];
    [_whiteBlipView.layer removeAllAnimations];
}

- (void)dealloc {
    [self stopAnimating];
    [super dealloc];
}

@end
