#import "LocalSendRadarBackgroundView.h"

static void LocalSendDrawVerticalGradient(CGContextRef context, CGRect frame, const CGFloat *topColor,
                                          const CGFloat *bottomColor) {
    CGFloat components[] = {topColor[0],    topColor[1],    topColor[2],    topColor[3],
                            bottomColor[0], bottomColor[1], bottomColor[2], bottomColor[3]};
    CGFloat locations[] = {0.0f, 1.0f};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, locations, 2);
    CGContextSaveGState(context);
    CGContextClipToRect(context, frame);
    CGContextDrawLinearGradient(context, gradient, CGPointMake(CGRectGetMidX(frame), CGRectGetMinY(frame)),
                                CGPointMake(CGRectGetMidX(frame), CGRectGetMaxY(frame)), 0);
    CGContextRestoreGState(context);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);
}

@implementation LocalSendRadarBackgroundView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.opaque = YES;
        self.backgroundColor = [UIColor colorWithWhite:0.18f alpha:1.0f];
        self.userInteractionEnabled = NO;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat contentTop[] = {0.34f, 0.34f, 0.34f, 1.0f};
    CGFloat contentBottom[] = {0.17f, 0.17f, 0.17f, 1.0f};
    CGRect content = self.bounds;
    LocalSendDrawVerticalGradient(context, content, contentTop, contentBottom);

    CGFloat washColors[] = {0.52f, 0.36f, 0.52f, 0.15f, 0.28f, 0.23f, 0.29f, 0.0f};
    CGFloat locations[] = {0.0f, 1.0f};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGGradientRef wash = CGGradientCreateWithColorComponents(colorSpace, washColors, locations, 2);
    CGContextSaveGState(context);
    CGContextClipToRect(context, content);
    CGPoint center = CGPointMake(width / 2.0f, CGRectGetMidY(content));
    CGContextDrawRadialGradient(context, wash, center, 0.0f, center, 205.0f, 0);
    CGContextRestoreGState(context);
    CGGradientRelease(wash);
    CGColorSpaceRelease(colorSpace);

}

@end
