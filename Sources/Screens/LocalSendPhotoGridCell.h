#import <UIKit/UIKit.h>

extern const NSUInteger LocalSendPhotosPerRow;

@class LocalSendPhotoGridCell;

@protocol LocalSendPhotoGridCellDelegate <NSObject>
- (void)photoGridCell:(LocalSendPhotoGridCell *)cell didSelectPhotoAtIndex:(NSUInteger)photoIndex;
@end

@interface LocalSendPhotoGridCell : UITableViewCell {
    NSMutableArray *_photoButtons;
    NSMutableArray *_selectionBadges;
    NSUInteger _photoIndexes[4];
    id<LocalSendPhotoGridCellDelegate> _delegate;
}
@property (nonatomic, assign) id<LocalSendPhotoGridCellDelegate> delegate;
- (void)setPhotoAtColumn:(NSUInteger)columnIndex
                   image:(UIImage *)image
              photoIndex:(NSUInteger)photoIndex
         selectionNumber:(NSUInteger)selectionNumber;
- (void)hidePhotoAtColumn:(NSUInteger)columnIndex;
@end
