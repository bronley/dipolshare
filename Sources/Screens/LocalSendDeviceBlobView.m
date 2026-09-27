#import "LocalSendDeviceBlobView.h"

@implementation LocalSendDeviceBlobView

- (id)initWithDevice:(NSDictionary *)device colorIndex:(NSUInteger)colorIndex scale:(CGFloat)scale {
    CGFloat imageWidth = 63.0f * scale;
    self = [super initWithFrame:CGRectMake(0.0f, 0.0f, 88.0f, imageWidth + 32.0f)];
    if (self != nil) {
        static NSString *const colors[] = {@"Blue", @"Green", @"Purple", @"Gold"};
        NSString *name = colors[colorIndex % 4];
        _imageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:name]];
        _imageView.frame = CGRectMake((88.0f - imageWidth) / 2.0f, 0.0f, imageWidth, imageWidth);
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_imageView];

        _nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(0.0f, imageWidth + 3.0f, 88.0f, 29.0f)];
        _nameLabel.backgroundColor = [UIColor clearColor];
        _nameLabel.textAlignment = UITextAlignmentCenter;
        _nameLabel.numberOfLines = 2;
        _nameLabel.lineBreakMode = UILineBreakModeTailTruncation;
        _nameLabel.font = [UIFont boldSystemFontOfSize:11.0f];
        _nameLabel.textColor = [UIColor colorWithWhite:0.84f alpha:1.0f];
        _nameLabel.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.65f];
        _nameLabel.shadowOffset = CGSizeMake(0.0f, 1.0f);
        [self addSubview:_nameLabel];
        [self updateDevice:device];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}

- (NSDictionary *)device {
    return _device;
}

- (void)updateDevice:(NSDictionary *)device {
    if (_device != device) {
        [_device release];
        _device = [device copy];
    }
    NSString *alias = [_device objectForKey:@"alias"];
    if (![alias isKindOfClass:[NSString class]] || [alias length] == 0) {
        alias = [_device objectForKey:@"model"];
    }
    _nameLabel.text = alias;
    self.accessibilityLabel = [NSString stringWithFormat:@"Send to %@", alias];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    _imageView.alpha = highlighted ? 0.75f : 1.0f;
}

- (void)dealloc {
    [_device release];
    [_imageView release];
    [_nameLabel release];
    [super dealloc];
}

@end
