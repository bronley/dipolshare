#import "LocalSendPhotoGridCell.h"

@interface LocalSendPhotoGridCell ()
- (void)photoButtonPressed:(UIButton *)button;
@end

@implementation LocalSendPhotoGridCell
@synthesize delegate = _delegate;

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.backgroundView = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
        _photoButtons = [[NSMutableArray alloc] init];
        _selectionBadges = [[NSMutableArray alloc] init];
        _videoBadges = [[NSMutableArray alloc] init];
        self.columnCount = 4;
    }
    return self;
}

- (NSUInteger)columnCount { return _columnCount; }

- (void)setColumnCount:(NSUInteger)columnCount {
    if (_columnCount == columnCount) return;
    _columnCount = columnCount;
    for (UIView *view in _photoButtons) [view removeFromSuperview];
    for (UIView *view in _selectionBadges) [view removeFromSuperview];
    for (UIView *view in _videoBadges) [view removeFromSuperview];
    [_photoButtons removeAllObjects];
    [_selectionBadges removeAllObjects];
    [_videoBadges removeAllObjects];
    for (NSUInteger columnIndex = 0; columnIndex < _columnCount; columnIndex++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.frame = CGRectZero;
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
        button.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
        button.imageView.contentMode = UIViewContentModeScaleAspectFit;
        button.clipsToBounds = YES;
        button.backgroundColor = [UIColor whiteColor];
        button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
        [button addTarget:self
                      action:@selector(photoButtonPressed:)
            forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:button];
        [_photoButtons addObject:button];

        UILabel *badge = [[UILabel alloc] initWithFrame:CGRectZero];
        badge.textAlignment = UITextAlignmentCenter;
        badge.font = [UIFont boldSystemFontOfSize:15];
        badge.textColor = [UIColor whiteColor];
        badge.backgroundColor = [UIColor colorWithRed:0.12 green:0.49 blue:0.91 alpha:0.9];
        badge.userInteractionEnabled = NO;
        [self.contentView addSubview:badge];
        [_selectionBadges addObject:badge];
        [badge release];
        UILabel *videoBadge = [[UILabel alloc] initWithFrame:CGRectZero];
        videoBadge.text = @"VIDEO";
        videoBadge.font = [UIFont boldSystemFontOfSize:10];
        videoBadge.textAlignment = UITextAlignmentCenter;
        videoBadge.textColor = [UIColor whiteColor];
        videoBadge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
        [self.contentView addSubview:videoBadge];
        [_videoBadges addObject:videoBadge];
        [videoBadge release];
        [self hidePhotoAtColumn:columnIndex];
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_columnCount == 0) return;
    CGFloat width = self.contentView.bounds.size.width;
    CGFloat tile = LocalSendPhotoTileSize(width, _columnCount);
    CGFloat gap = LocalSendPhotoGridSpacing(width);
    CGFloat top = LocalSendPhotoGridRowPadding(width) / 2;
    CGFloat left = floor((width - (_columnCount * tile + (_columnCount - 1) * gap)) / 2);
    for (NSUInteger column = 0; column < _columnCount; column++) {
        CGFloat x = left + column * (tile + gap);
        UIButton *button = [_photoButtons objectAtIndex:column];
        CGFloat border = LocalSendPhotoFrameBorder(width);
        UIImage *image = [button imageForState:UIControlStateNormal];
        CGRect frame = LocalSendPhotoFrameInSlot(CGRectMake(x, top, tile, tile), image.size, border);
        button.frame = frame;
        button.contentEdgeInsets = UIEdgeInsetsMake(border, border, border, border);
        ((UILabel *)[_selectionBadges objectAtIndex:column]).frame =
            CGRectMake(CGRectGetMaxX(frame) - 28 - border, frame.origin.y + border, 28, 24);
        ((UILabel *)[_videoBadges objectAtIndex:column]).frame =
            CGRectMake(frame.origin.x + border, CGRectGetMaxY(frame) - 20 - border, 45, 20);
    }
}

- (void)setPhotoAtColumn:(NSUInteger)columnIndex
                   image:(UIImage *)image
              photoIndex:(NSUInteger)photoIndex
         selectionNumber:(NSUInteger)selectionNumber
                 isVideo:(BOOL)isVideo {
    UIButton *button = [_photoButtons objectAtIndex:columnIndex];
    button.tag = photoIndex + 1;
    button.hidden = NO;
    button.accessibilityLabel = [NSString stringWithFormat:@"%@ %lu", isVideo ? @"Video" : @"Photo", (unsigned long)(photoIndex + 1)];
    [button setImage:image forState:UIControlStateNormal];
    [self setNeedsLayout];
    [self setSelectionNumber:selectionNumber atColumn:columnIndex];
    ((UILabel *)[_videoBadges objectAtIndex:columnIndex]).hidden = !isVideo;
}

- (void)setSelectionNumber:(NSUInteger)selectionNumber atColumn:(NSUInteger)columnIndex {
    UILabel *badge = [_selectionBadges objectAtIndex:columnIndex];
    badge.hidden = selectionNumber == 0;
    badge.text =
        selectionNumber == 0 ? nil : [NSString stringWithFormat:@"%lu", (unsigned long)selectionNumber];
}

- (void)hidePhotoAtColumn:(NSUInteger)columnIndex {
    UIButton *button = [_photoButtons objectAtIndex:columnIndex];
    UILabel *badge = [_selectionBadges objectAtIndex:columnIndex];
    button.tag = 0;
    button.hidden = YES;
    [button setImage:nil forState:UIControlStateNormal];
    badge.hidden = YES;
    badge.text = nil;
    ((UILabel *)[_videoBadges objectAtIndex:columnIndex]).hidden = YES;
}

- (void)photoButtonPressed:(UIButton *)button {
    NSUInteger columnIndex = [_photoButtons indexOfObjectIdenticalTo:button];
    if (columnIndex == NSNotFound || button.tag == 0) {
        return;
    }
    [_delegate photoGridCell:self didSelectPhotoAtIndex:(NSUInteger)button.tag - 1];
}

- (void)dealloc {
    [_photoButtons release];
    [_selectionBadges release];
    [_videoBadges release];
    [super dealloc];
}
@end
