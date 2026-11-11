#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

static inline NSUInteger LocalSendPhotoColumnsForWidth(CGFloat width) {
    return width < 468.0f ? 4 : MAX((NSUInteger)3, (NSUInteger)floor(width / 144.0f));
}
static inline CGFloat LocalSendPhotoGridMargin(CGFloat width) {
    return width < 468.0f ? 4.0f : 28.0f;
}
static inline CGFloat LocalSendPhotoGridRowPadding(CGFloat width) {
    return width < 468.0f ? 8.0f : 28.0f;
}
static inline CGFloat LocalSendPhotoTileSize(CGFloat width, NSUInteger columns) {
    CGFloat minimumGap = width < 468.0f ? 6.0f : 16.0f;
    return MIN(120.0f, floor((width - 2 * LocalSendPhotoGridMargin(width) -
                              (columns - 1) * minimumGap) / columns));
}
static inline CGFloat LocalSendPhotoGridSpacing(CGFloat width) {
    NSUInteger columns = LocalSendPhotoColumnsForWidth(width);
    return (width - 2 * LocalSendPhotoGridMargin(width) -
            columns * LocalSendPhotoTileSize(width, columns)) / (columns - 1);
}
static inline CGFloat LocalSendPhotoFrameBorder(CGFloat width) {
    return width < 468.0f ? 2.0f : 6.0f;
}
static inline CGRect LocalSendPhotoFrameInSlot(CGRect slot, CGSize image, CGFloat border) {
    CGFloat available = MAX(1.0f, MIN(slot.size.width, slot.size.height) - 2 * border);
    if (image.width <= 0 || image.height <= 0) image = CGSizeMake(1, 1);
    CGFloat scale = MIN(available / image.width, available / image.height);
    CGSize framed = CGSizeMake(image.width * scale + 2 * border, image.height * scale + 2 * border);
    return CGRectMake(CGRectGetMidX(slot) - framed.width / 2,
                      CGRectGetMidY(slot) - framed.height / 2, framed.width, framed.height);
}
