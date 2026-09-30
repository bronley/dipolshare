#import <Foundation/Foundation.h>

extern NSString *const ALAssetPropertyType;
extern NSString *const ALAssetTypePhoto;
extern NSString *const ALAssetTypeVideo;

@interface ALAssetsLibrary : NSObject
@end

@interface ALAssetRepresentation : NSObject {
    NSData *_testData;
    NSString *_testFileName;
    NSString *_testUTI;
    BOOL _testShouldFail;
    BOOL _testTracksTemporaries;
    NSUInteger _testReadCount;
}
- (id)initWithData:(NSData *)data fileName:(NSString *)fileName fail:(BOOL)shouldFail;
- (NSString *)filename;
- (NSString *)UTI;
- (void)setTestUTI:(NSString *)type;
- (void)setTestTracksTemporaries:(BOOL)value;
- (long long)size;
- (NSUInteger)getBytes:(uint8_t *)bytes
            fromOffset:(long long)offset
                length:(NSUInteger)length
                 error:(NSError **)error;
- (NSUInteger)testReadCount;
@end

@interface ALAsset : NSObject {
    ALAssetRepresentation *_testRepresentation;
    NSString *_testType;
}
- (id)initWithRepresentation:(ALAssetRepresentation *)representation;
- (ALAssetRepresentation *)defaultRepresentation;
- (id)valueForProperty:(NSString *)property;
- (void)setTestType:(NSString *)type;
@end
