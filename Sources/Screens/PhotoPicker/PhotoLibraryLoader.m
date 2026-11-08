#import "PhotoLibraryLoader.h"
#import "PickerAsset.h"

static const NSUInteger PhotoLoadingBatchSize = 32;

@interface PhotoLibraryLoader ()
- (BOOL)isCancelled;
- (void)enumeratePhotoGroup:(ALAssetsGroup *)group;
- (void)enqueuePhotoEnumerationCompletion:(NSError *)error;
- (void)finishPhotoEnumeration:(NSError *)error;
- (void)deliverEntries:(NSArray *)entries;
- (void)deliverCompletion:(NSDictionary *)result;
@end

@implementation PhotoLibraryLoader
@synthesize delegate = _delegate, library = _library;

- (id)init {
    ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
    self = [self initWithLibrary:library];
    [library release];
    return self;
}

- (id)initWithLibrary:(ALAssetsLibrary *)library {
    self = [super init];
    if (self) {
        _library = [library retain];
        _photoLoadQueue = [[NSOperationQueue alloc] init];
        [_photoLoadQueue setMaxConcurrentOperationCount:1];
        _loadingEntries = [[NSMutableArray alloc] init];
        _loadedAssetURLs = [[NSMutableSet alloc] init];
    }
    return self;
}

- (BOOL)isCancelled {
    @synchronized(self) {
        return _cancelled;
    }
}

- (void)cancel {
    @synchronized(self) {
        _cancelled = YES;
        _delegate = nil;
        [_photoLoadQueue cancelAllOperations];
    }
}

- (void)start {
    if (_started || [self isCancelled]) {
        return;
    }
    _started = YES;
    [_library enumerateGroupsWithTypes:ALAssetsGroupAll | ALAssetsGroupLibrary
        usingBlock:^(ALAssetsGroup *group, BOOL *stop) {
            @synchronized(self) {
                if (_cancelled || _completionEnqueued) {
                    *stop = YES;
                    return;
                }
                if (group == nil) {
                    [self enqueuePhotoEnumerationCompletion:nil];
                    return;
                }
                NSInvocationOperation *operation = [[NSInvocationOperation alloc]
                    initWithTarget:self selector:@selector(enumeratePhotoGroup:) object:group];
                [_photoLoadQueue addOperation:operation];
                [operation release];
            }
        }
        failureBlock:^(NSError *error) {
            [self enqueuePhotoEnumerationCompletion:error];
        }];
}

- (void)enqueuePhotoEnumerationCompletion:(NSError *)error {
    @synchronized(self) {
        if (_cancelled || _completionEnqueued) {
            return;
        }
        _completionEnqueued = YES;
        NSInvocationOperation *operation = [[NSInvocationOperation alloc]
            initWithTarget:self selector:@selector(finishPhotoEnumeration:) object:error];
        for (NSOperation *pending in [_photoLoadQueue operations]) {
            [operation addDependency:pending];
        }
        [_photoLoadQueue addOperation:operation];
        [operation release];
    }
}

- (void)enumeratePhotoGroup:(ALAssetsGroup *)group {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if ([self isCancelled]) {
        [pool drain];
        return;
    }
    NSMutableArray *batch = [[NSMutableArray alloc] initWithCapacity:PhotoLoadingBatchSize];
    [group setAssetsFilter:[ALAssetsFilter allAssets]];
    NSUInteger remaining = (NSUInteger)MAX(0, [group numberOfAssets]);
    while (remaining > 0 && ![self isCancelled]) {
        NSAutoreleasePool *batchPool = [[NSAutoreleasePool alloc] init];
        NSUInteger count = MIN(remaining, PhotoLoadingBatchSize);
        remaining -= count;
        NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(remaining, count)];
        [group enumerateAssetsAtIndexes:indexes options:NSEnumerationReverse
            usingBlock:^(ALAsset *photoAsset, NSUInteger index, BOOL *stop) {
                if ([self isCancelled]) {
                    *stop = YES;
                    return;
                }
                if (photoAsset == nil) {
                    return;
                }
                NSString *assetURL = [[[photoAsset defaultRepresentation] url] absoluteString];
                if ([assetURL length] != 0 && ![_loadedAssetURLs containsObject:assetURL]) {
                    [_loadedAssetURLs addObject:assetURL];
                    PickerAsset *entry = [[PickerAsset alloc] initWithAsset:photoAsset];
                    [_loadingEntries addObject:entry];
                    [batch addObject:entry];
                    [entry release];
                }
            }];
        if ([batch count] > 0 && ![self isCancelled]) {
            [self performSelectorOnMainThread:@selector(deliverEntries:)
                                   withObject:batch waitUntilDone:YES];
        }
        [batch removeAllObjects];
        [batchPool drain];
    }
    [batch release];
    [pool drain];
}

- (void)finishPhotoEnumeration:(NSError *)error {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (![self isCancelled]) {
        NSArray *sortedEntries = [_loadingEntries sortedArrayUsingComparator:
            ^NSComparisonResult(PickerAsset *first, PickerAsset *second) {
                return [second->date compare:first->date];
            }];
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObject:sortedEntries forKey:@"entries"];
        if (error != nil) {
            [result setObject:error forKey:@"error"];
        }
        [self performSelectorOnMainThread:@selector(deliverCompletion:)
                               withObject:result waitUntilDone:YES];
    }
    [_loadingEntries removeAllObjects];
    [_loadedAssetURLs removeAllObjects];
    [pool drain];
}

- (void)deliverEntries:(NSArray *)entries {
    if (![self isCancelled]) {
        [_delegate photoLibraryLoader:self didLoadEntries:entries];
    }
}

- (void)deliverCompletion:(NSDictionary *)result {
    if (![self isCancelled]) {
        [_delegate photoLibraryLoader:self didFinishWithEntries:[result objectForKey:@"entries"]
                               error:[result objectForKey:@"error"]];
    }
}

- (void)dealloc {
    [_library release];
    [_photoLoadQueue release];
    [_loadingEntries release];
    [_loadedAssetURLs release];
    [super dealloc];
}
@end
