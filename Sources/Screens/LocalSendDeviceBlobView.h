#import <UIKit/UIKit.h>

@interface LocalSendDeviceBlobView : UIControl {
    NSDictionary *_device;
    UIImageView *_imageView;
    UILabel *_nameLabel;
}

@property (nonatomic, readonly) NSDictionary *device;

- (id)initWithDevice:(NSDictionary *)device colorIndex:(NSUInteger)colorIndex scale:(CGFloat)scale;
- (void)updateDevice:(NSDictionary *)device;

@end
