#import "PhotoSaveOverlay.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

@interface PhotoSaveOverlay ()
- (void)configureDimmingBackgroundAndModalAccessibility;
- (void)addSavingPanel;
- (void)addSavingStatusLabel;
- (void)addActivityIndicator;
@end

@implementation PhotoSaveOverlay

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self configureDimmingBackgroundAndModalAccessibility];
        [self addSavingPanel];
        [self addSavingStatusLabel];
        [self addActivityIndicator];
    }
    return self;
}

- (void)configureDimmingBackgroundAndModalAccessibility {
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.35f];
    if ([self respondsToSelector:@selector(setAccessibilityViewIsModal:)]) {
        self.accessibilityViewIsModal = YES;
    }
}

- (void)addSavingPanel {
    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    _panel.backgroundColor = [UIColor colorWithWhite:0.05f alpha:0.88f];
    _panel.layer.cornerRadius = 12.0f;
    [self addSubview:_panel];
}

- (void)addSavingStatusLabel {
    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.backgroundColor = [UIColor clearColor];
    _label.textColor = [UIColor whiteColor];
    _label.font = [UIFont boldSystemFontOfSize:20.0f];
    _label.textAlignment = UITextAlignmentCenter;
    _label.text = @"Saving...";
    [_panel addSubview:_label];
}

- (void)addActivityIndicator {
    _activityIndicator =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    [_panel addSubview:_activityIndicator];
    [_activityIndicator startAnimating];
}

- (void)setCompletedPhotos:(NSUInteger)completed total:(NSUInteger)total {
    _label.text = [NSString stringWithFormat:@"Saving %lu of %lu…",
        (unsigned long)MIN(completed + 1, total), (unsigned long)total];
    _label.adjustsFontSizeToFitWidth = YES;
    _label.minimumFontSize = 12.0f;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = MIN(260.0f, self.bounds.size.width - 40.0f);
    _panel.frame = CGRectMake(floorf((self.bounds.size.width - width) / 2.0f),
                              floorf((self.bounds.size.height - 120.0f) / 2.0f), width, 120.0f);
    _label.frame = CGRectMake(16.0f, 25.0f, width - 32.0f, 28.0f);
    _activityIndicator.center = CGPointMake(width / 2.0f, 84.0f);
}

- (void)dealloc {
    [_activityIndicator stopAnimating];
    [_activityIndicator release];
    [_label release];
    [_panel release];
    [super dealloc];
}
@end
