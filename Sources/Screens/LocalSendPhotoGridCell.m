#import "LocalSendPhotoGridCell.h"

const NSUInteger LocalSendPhotosPerRow = 4;

@interface LocalSendPhotoGridCell ()
- (void)photoButtonPressed:(UIButton *)button;
@end

@implementation LocalSendPhotoGridCell
@synthesize delegate = _delegate;

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _photoButtons = [[NSMutableArray alloc] initWithCapacity:LocalSendPhotosPerRow];
        _selectionBadges = [[NSMutableArray alloc] initWithCapacity:LocalSendPhotosPerRow];
        for (NSUInteger columnIndex = 0; columnIndex < LocalSendPhotosPerRow; columnIndex++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
            button.frame = CGRectMake(4 + columnIndex * 78, 4, 72, 72);
            button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
            [button addTarget:self
                          action:@selector(photoButtonPressed:)
                forControlEvents:UIControlEventTouchUpInside];
            [self.contentView addSubview:button];
            [_photoButtons addObject:button];

            UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(48 + columnIndex * 78, 4, 28, 24)];
            badge.textAlignment = UITextAlignmentCenter;
            badge.font = [UIFont boldSystemFontOfSize:15];
            badge.textColor = [UIColor whiteColor];
            badge.backgroundColor = [UIColor colorWithRed:0.12 green:0.49 blue:0.91 alpha:0.9];
            badge.userInteractionEnabled = NO;
            [self.contentView addSubview:badge];
            [_selectionBadges addObject:badge];
            [badge release];
            [self hidePhotoAtColumn:columnIndex];
        }
    }
    return self;
}

- (void)setPhotoAtColumn:(NSUInteger)columnIndex
                   image:(UIImage *)image
              photoIndex:(NSUInteger)photoIndex
         selectionNumber:(NSUInteger)selectionNumber {
    UIButton *button = [_photoButtons objectAtIndex:columnIndex];
    UILabel *badge = [_selectionBadges objectAtIndex:columnIndex];
    _photoIndexes[columnIndex] = photoIndex;
    button.hidden = NO;
    button.accessibilityLabel = [NSString stringWithFormat:@"Photo %lu", (unsigned long)(photoIndex + 1)];
    [button setBackgroundImage:image forState:UIControlStateNormal];
    badge.hidden = selectionNumber == 0;
    badge.text =
        selectionNumber == 0 ? nil : [NSString stringWithFormat:@"%lu", (unsigned long)selectionNumber];
}

- (void)hidePhotoAtColumn:(NSUInteger)columnIndex {
    UIButton *button = [_photoButtons objectAtIndex:columnIndex];
    UILabel *badge = [_selectionBadges objectAtIndex:columnIndex];
    _photoIndexes[columnIndex] = NSNotFound;
    button.hidden = YES;
    [button setBackgroundImage:nil forState:UIControlStateNormal];
    badge.hidden = YES;
    badge.text = nil;
}

- (void)photoButtonPressed:(UIButton *)button {
    NSUInteger columnIndex = [_photoButtons indexOfObjectIdenticalTo:button];
    if (columnIndex == NSNotFound || _photoIndexes[columnIndex] == NSNotFound) {
        return;
    }
    [_delegate photoGridCell:self didSelectPhotoAtIndex:_photoIndexes[columnIndex]];
}

- (void)dealloc {
    [_photoButtons release];
    [_selectionBadges release];
    [super dealloc];
}
@end
