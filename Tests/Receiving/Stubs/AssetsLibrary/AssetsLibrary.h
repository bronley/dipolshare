#import <Foundation/Foundation.h>

@interface ALAssetsLibrary : NSObject
- (void)writeImageDataToSavedPhotosAlbum:(NSData *)data
                              metadata:(NSDictionary *)metadata
                       completionBlock:(void (^)(NSURL *, NSError *))completion;
@end
