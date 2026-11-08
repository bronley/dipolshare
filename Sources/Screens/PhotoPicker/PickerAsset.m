#import "PickerAsset.h"

@implementation PickerAsset
- (id)initWithAsset:(ALAsset *)photoAsset {
    self = [super init];
    if (self) {
        asset = [photoAsset retain];
        id creationDate = [photoAsset valueForProperty:ALAssetPropertyDate];
        date = [([creationDate isKindOfClass:[NSDate class]] ? creationDate : [NSDate distantPast]) retain];
        isVideo = [[photoAsset valueForProperty:ALAssetPropertyType] isEqualToString:ALAssetTypeVideo];
    }
    return self;
}
- (void)dealloc {
    [asset release];
    [date release];
    [super dealloc];
}
@end
