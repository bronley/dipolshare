#import <Foundation/Foundation.h>

extern NSString *const ALAssetPropertyDate;
extern NSString *const ALAssetPropertyType;
extern NSString *const ALAssetTypePhoto;
extern NSString *const ALAssetTypeVideo;
#define ALAssetsGroupAll 0xFFFFFFFF
#define ALAssetsGroupLibrary 1

@interface ALAssetRepresentation : NSObject {
    NSURL *_url;
}
- (id)initWithURL:(NSURL *)url;
- (NSURL *)url;
@end

@interface ALAsset : NSObject {
    ALAssetRepresentation *_representation;
    id _date;
    NSString *_type;
}
- (id)initWithURL:(NSURL *)url date:(id)date video:(BOOL)video;
- (ALAssetRepresentation *)defaultRepresentation;
- (id)valueForProperty:(NSString *)property;
@end

@interface ALAssetsFilter : NSObject
+ (id)allAssets;
@end

@interface ALAssetsGroup : NSObject {
    NSArray *_assets;
@public
    NSUInteger enumerationCount;
    NSUInteger maximumBatch;
    BOOL enumeratedOnMain;
}
- (id)initWithAssets:(NSArray *)assets;
- (NSInteger)numberOfAssets;
- (void)setAssetsFilter:(ALAssetsFilter *)filter;
- (void)enumerateAssetsAtIndexes:(NSIndexSet *)indexes options:(NSEnumerationOptions)options
                     usingBlock:(void (^)(ALAsset *, NSUInteger, BOOL *))block;
@end

@interface ALAssetsLibrary : NSObject {
    void (^_groupsBlock)(ALAssetsGroup *, BOOL *);
    void (^_failureBlock)(NSError *);
@public
    NSUInteger starts;
}
- (void)enumerateGroupsWithTypes:(NSUInteger)types
                    usingBlock:(void (^)(ALAssetsGroup *, BOOL *))block
                  failureBlock:(void (^)(NSError *))failure;
- (BOOL)emitGroup:(ALAssetsGroup *)group;
- (void)finishWithError:(NSError *)error;
@end
