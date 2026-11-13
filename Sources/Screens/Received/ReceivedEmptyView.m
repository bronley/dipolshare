#import "ReceivedEmptyView.h"
#import "RadarLayout.h"

@implementation ReceivedEmptyView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.backgroundColor = [UIColor whiteColor];
        _satelliteImageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"Satellite"]];
        _satelliteImageView.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_satelliteImageView];

        _messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _messageLabel.backgroundColor = [UIColor clearColor];
        _messageLabel.textColor = [UIColor darkGrayColor];
        _messageLabel.font = [UIFont systemFontOfSize:16.0f];
        _messageLabel.textAlignment = UITextAlignmentCenter;
        _messageLabel.text = @"No received files yet.";
        [self addSubview:_messageLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    CGFloat iconSize = MIN(142.0f, width - 32.0f);
    CGFloat groupHeight = iconSize + 16.0f + 24.0f;
    CGFloat top = MAX(0.0f, (height - groupHeight) / 2.0f);
    CGFloat messageTop = top + iconSize + 16.0f;
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        CGFloat radarCenterY = [RadarLayout tabletRadarCenterYInBounds:self.bounds];
        // The radar face is 4 points above its canvas center. Match the
        // discovery heading's vertical center while retaining a 24-point label.
        top = radarCenterY - 4.0f - iconSize / 2.0f;
        messageTop = radarCenterY + 101.0f + (38.0f - 24.0f) / 2.0f;
    }
    _satelliteImageView.frame = CGRectMake((width - iconSize) / 2.0f, top, iconSize, iconSize);
    _messageLabel.frame = CGRectMake(12.0f, messageTop, width - 24.0f, 24.0f);
}

- (void)dealloc {
    [_satelliteImageView release];
    [_messageLabel release];
    [super dealloc];
}

@end
