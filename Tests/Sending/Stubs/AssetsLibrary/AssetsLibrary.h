#import <Foundation/Foundation.h>

@interface ALAssetsLibrary : NSObject
@end

@interface ALAssetRepresentation : NSObject {
    NSData *_testData;
    NSString *_testFileName;
    BOOL _testShouldFail;
    NSUInteger _testReadCount;
}
- (id)initWithData:(NSData *)data fileName:(NSString *)fileName fail:(BOOL)shouldFail;
- (NSString *)filename;
- (NSUInteger)size;
- (NSUInteger)getBytes:(uint8_t *)bytes
            fromOffset:(long long)offset
                length:(NSUInteger)length
                 error:(NSError **)error;
- (NSUInteger)testReadCount;
@end

@interface ALAsset : NSObject {
    ALAssetRepresentation *_testRepresentation;
}
- (id)initWithRepresentation:(ALAssetRepresentation *)representation;
- (ALAssetRepresentation *)defaultRepresentation;
@end
