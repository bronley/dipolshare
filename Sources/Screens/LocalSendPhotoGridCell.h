#import <UIKit/UIKit.h>

extern const NSUInteger LocalSendPhotosPerRow;

@class LocalSendPhotoGridCell;

@protocol LocalSendPhotoGridCellDelegate <NSObject>
- (void)photoGridCell:(LocalSendPhotoGridCell *)cell didSelectPhotoAtIndex:(NSUInteger)photoIndex;
@end

@interface LocalSendPhotoGridCell : UITableViewCell {
    NSMutableArray *_photoButtons;
    NSMutableArray *_selectionBadges;
    NSMutableArray *_videoBadges;
    NSUInteger _photoIndexes[4];
    id<LocalSendPhotoGridCellDelegate> _delegate;
}
@property (nonatomic, assign) id<LocalSendPhotoGridCellDelegate> delegate;
- (void)setPhotoAtColumn:(NSUInteger)columnIndex
                   image:(UIImage *)image
              photoIndex:(NSUInteger)photoIndex
         selectionNumber:(NSUInteger)selectionNumber
                 isVideo:(BOOL)isVideo;
- (void)setSelectionNumber:(NSUInteger)selectionNumber atColumn:(NSUInteger)columnIndex;
- (void)hidePhotoAtColumn:(NSUInteger)columnIndex;
@end
