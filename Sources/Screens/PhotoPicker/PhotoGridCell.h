#import <UIKit/UIKit.h>

extern const NSUInteger PhotosPerRow;

@class PhotoGridCell;

@protocol PhotoGridCellDelegate <NSObject>
- (void)photoGridCell:(PhotoGridCell *)cell didSelectPhotoAtIndex:(NSUInteger)photoIndex;
@end

@interface PhotoGridCell : UITableViewCell {
    NSMutableArray *_photoButtons;
    NSMutableArray *_selectionBadges;
    NSMutableArray *_videoBadges;
    NSUInteger _photoIndexes[4];
    id<PhotoGridCellDelegate> _delegate;
}
@property (nonatomic, assign) id<PhotoGridCellDelegate> delegate;
- (void)setPhotoAtColumn:(NSUInteger)columnIndex
                   image:(UIImage *)image
              photoIndex:(NSUInteger)photoIndex
         selectionNumber:(NSUInteger)selectionNumber
                 isVideo:(BOOL)isVideo;
- (void)setSelectionNumber:(NSUInteger)selectionNumber atColumn:(NSUInteger)columnIndex;
- (void)hidePhotoAtColumn:(NSUInteger)columnIndex;
@end
