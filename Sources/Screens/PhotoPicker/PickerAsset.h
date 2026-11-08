#import <Foundation/Foundation.h>
#import <AssetsLibrary/AssetsLibrary.h>

@interface PickerAsset : NSObject {
@public
    ALAsset *asset;
    NSDate *date;
    BOOL isVideo;
}
- (id)initWithAsset:(ALAsset *)photoAsset;
@end
