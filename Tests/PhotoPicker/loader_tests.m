#import "PhotoLibraryLoader.h"
#import "PickerAsset.h"

NSString *const ALAssetPropertyDate = @"date";
NSString *const ALAssetPropertyType = @"type";
NSString *const ALAssetTypePhoto = @"photo";
NSString *const ALAssetTypeVideo = @"video";
static NSUInteger checks, failures, destroyedLoaders;

static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) failures++;
    printf("%s %s\n", condition ? "PASS" : "FAIL", [message UTF8String]);
}
static BOOL WaitFor(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!condition() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

@implementation ALAssetRepresentation
- (id)initWithURL:(NSURL *)url {
    if ((self = [super init])) _url = [url retain];
    return self;
}
- (NSURL *)url { return _url; }
- (void)dealloc { [_url release]; [super dealloc]; }
@end
@implementation ALAsset
- (id)initWithURL:(NSURL *)url date:(id)date video:(BOOL)video {
    if ((self = [super init])) {
        _representation = [[ALAssetRepresentation alloc] initWithURL:url];
        _date = [date retain];
        _type = [(video ? ALAssetTypeVideo : ALAssetTypePhoto) retain];
    }
    return self;
}
- (ALAssetRepresentation *)defaultRepresentation { return _representation; }
- (id)valueForProperty:(NSString *)property {
    return [property isEqual:ALAssetPropertyDate] ? _date : _type;
}
- (void)dealloc { [_representation release]; [_date release]; [_type release]; [super dealloc]; }
@end
@implementation ALAssetsFilter
+ (id)allAssets { return nil; }
@end
@implementation ALAssetsGroup
- (id)initWithAssets:(NSArray *)assets {
    if ((self = [super init])) _assets = [assets copy];
    return self;
}
- (NSInteger)numberOfAssets { return [_assets count]; }
- (void)setAssetsFilter:(ALAssetsFilter *)filter {}
- (void)enumerateAssetsAtIndexes:(NSIndexSet *)indexes options:(NSEnumerationOptions)options
                     usingBlock:(void (^)(ALAsset *, NSUInteger, BOOL *))block {
    @synchronized(self) {
        enumerationCount++;
        maximumBatch = MAX(maximumBatch, [indexes count]);
        enumeratedOnMain |= [NSThread isMainThread];
    }
    [indexes enumerateIndexesWithOptions:options usingBlock:^(NSUInteger index, BOOL *stop) {
        block([_assets objectAtIndex:index], index, stop);
    }];
}
- (void)dealloc { [_assets release]; [super dealloc]; }
@end
@implementation ALAssetsLibrary
- (void)enumerateGroupsWithTypes:(NSUInteger)types
                    usingBlock:(void (^)(ALAssetsGroup *, BOOL *))block
                  failureBlock:(void (^)(NSError *))failure {
    starts++;
    _groupsBlock = [block copy];
    _failureBlock = [failure copy];
}
- (BOOL)emitGroup:(ALAssetsGroup *)group {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    BOOL stop = NO;
    if (_groupsBlock != nil) _groupsBlock(group, &stop);
    [pool drain];
    return stop;
}
- (void)finishWithError:(NSError *)error {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (error != nil) _failureBlock(error);
    else if (_groupsBlock != nil) [self emitGroup:nil];
    [_groupsBlock release]; _groupsBlock = nil;
    [_failureBlock release]; _failureBlock = nil;
    [pool drain];
}
- (void)dealloc { [_groupsBlock release]; [_failureBlock release]; [super dealloc]; }
@end

@interface TrackedLoader : PhotoLibraryLoader
@end
@implementation TrackedLoader
- (void)dealloc {
    @synchronized([TrackedLoader class]) { destroyedLoaders++; }
    [super dealloc];
}
@end
static NSUInteger DestroyedLoaders(void) {
    @synchronized([TrackedLoader class]) { return destroyedLoaders; }
}

@interface Observer : NSObject <PhotoLibraryLoaderDelegate> {
@public
    NSMutableArray *batches;
    NSArray *entries;
    NSError *error;
    NSUInteger completions;
    BOOL allOnMain;
    BOOL cancelOnBatch;
}
@end
@implementation Observer
- (id)init {
    if ((self = [super init])) { batches = [[NSMutableArray alloc] init]; allOnMain = YES; }
    return self;
}
- (void)photoLibraryLoader:(PhotoLibraryLoader *)loader didLoadEntries:(NSArray *)batch {
    allOnMain &= [NSThread isMainThread];
    [batches addObject:[[batch copy] autorelease]];
    if (cancelOnBatch) [loader cancel];
}
- (void)photoLibraryLoader:(PhotoLibraryLoader *)loader didFinishWithEntries:(NSArray *)result error:(NSError *)failure {
    allOnMain &= [NSThread isMainThread];
    completions++;
    [entries release]; entries = [result copy];
    [error release]; error = [failure retain];
}
- (void)dealloc { [batches release]; [entries release]; [error release]; [super dealloc]; }
@end

static ALAsset *Asset(NSString *identifier, id date, BOOL video) {
    NSURL *url = identifier == nil ? nil : [NSURL URLWithString:[@"assets-library://" stringByAppendingString:identifier]];
    return [[[ALAsset alloc] initWithURL:url date:date video:video] autorelease];
}
static ALAssetsGroup *Group(NSArray *assets) {
    return [[[ALAssetsGroup alloc] initWithAssets:assets] autorelease];
}
static TrackedLoader *Loader(ALAssetsLibrary **library, Observer *observer) {
    *library = [[[ALAssetsLibrary alloc] init] autorelease];
    TrackedLoader *loader = [[TrackedLoader alloc] initWithLibrary:*library];
    loader.delegate = observer;
    return loader;
}
static void Dispose(TrackedLoader *loader) {
    NSUInteger before = DestroyedLoaders();
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [loader cancel];
    [loader release];
    [pool drain];
    Check(WaitFor(^BOOL { return DestroyedLoaders() > before; }), @"loader and operation ownership unwind after completion/cancellation");
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    Observer *observer = [[Observer alloc] init];
    ALAssetsLibrary *library;
    TrackedLoader *loader = Loader(&library, observer);
    NSMutableArray *assets = [NSMutableArray array];
    for (NSUInteger i = 0; i < 70; i++) {
        [assets addObject:Asset([NSString stringWithFormat:@"%lu", (unsigned long)i],
            [NSDate dateWithTimeIntervalSince1970:i], i % 2 == 0)];
    }
    ALAssetsGroup *group = Group(assets);
    [loader start]; [loader start];
    Check(library->starts == 1 && loader.library == library, @"start is idempotent and exposes the retained source library");
    [library emitGroup:group];
    [library emitGroup:Group([NSArray arrayWithObjects:[assets objectAtIndex:0],
        Asset(@"missing-date", @"invalid date", NO), Asset(nil, nil, NO), nil])];
    [library finishWithError:nil];
    Check(WaitFor(^BOOL { return observer->completions == 1; }), @"enumeration completes once after all groups");
    Check(observer->allOnMain && !group->enumeratedOnMain, @"enumeration runs in background and delegate delivery runs on main");
    Check([observer->entries count] == 71, @"duplicate URLs and missing URLs are excluded across groups");
    Check(group->maximumBatch == 32 && [observer->batches count] == 4, @"large libraries arrive in bounded batches");
    BOOL sorted = YES, bounded = YES;
    NSUInteger total = 0;
    for (NSArray *batch in observer->batches) { bounded &= [batch count] <= 32; total += [batch count]; }
    for (NSUInteger i = 1; i < [observer->entries count]; i++) {
        sorted &= [((PickerAsset *)[observer->entries objectAtIndex:i-1])->date
            compare:((PickerAsset *)[observer->entries objectAtIndex:i])->date] != NSOrderedAscending;
    }
    Check(sorted && bounded && total == 71, @"final results are newest-first with every delivered entry included");
    Check([((PickerAsset *)[observer->entries lastObject])->date isEqual:[NSDate distantPast]], @"invalid dates sort last");
    Check(((PickerAsset *)[observer->entries objectAtIndex:1])->isVideo &&
          ((PickerAsset *)[observer->entries objectAtIndex:1])->asset == [assets objectAtIndex:68], @"entry preserves video type and original asset identity for selection");
    Check(observer->error == nil, @"successful enumeration reports no error");
    Dispose(loader); [observer release];

    observer = [[Observer alloc] init]; loader = Loader(&library, observer);
    [loader start]; [library finishWithError:nil];
    Check(WaitFor(^BOOL { return observer->completions == 1; }) && [observer->entries count] == 0,
          @"empty library completes with an empty result");
    Dispose(loader); [observer release];

    observer = [[Observer alloc] init]; loader = Loader(&library, observer);
    [loader start]; [library emitGroup:Group([assets subarrayWithRange:NSMakeRange(0, 3)])];
    NSError *denied = [NSError errorWithDomain:@"Photos" code:1 userInfo:nil];
    [library finishWithError:denied];
    Check(WaitFor(^BOOL { return observer->completions == 1; }) && observer->error == denied && [observer->entries count] == 3,
          @"library failure preserves already loaded entries and reports its error");
    Dispose(loader); [observer release];

    observer = [[Observer alloc] init]; loader = Loader(&library, observer);
    [loader cancel]; [loader start];
    Check(library->starts == 0 && loader.delegate == nil, @"cancel before start prevents enumeration and detaches the delegate");
    Dispose(loader); [observer release];

    observer = [[Observer alloc] init]; observer->cancelOnBatch = YES;
    loader = Loader(&library, observer);
    [loader start]; [library emitGroup:Group(assets)]; [library finishWithError:nil];
    Check(WaitFor(^BOOL { return [observer->batches count] == 1; }), @"first batch is available before loading finishes");
    Dispose(loader);
    Check([observer->batches count] == 1 && observer->completions == 0, @"cancel from a batch callback suppresses later batches and completion");
    [observer release];

    observer = [[Observer alloc] init]; loader = Loader(&library, observer);
    [loader start]; [loader cancel];
    NSUInteger before = DestroyedLoaders();
    [loader release];
    Check(DestroyedLoaders() == before, @"pending library callbacks keep their loader alive after the screen releases it");
    Check([library emitGroup:Group(assets)], @"late group callback is told to stop after cancellation");
    [library finishWithError:denied];
    Check(WaitFor(^BOOL { return DestroyedLoaders() == before + 1; }), @"late library callback releases the detached loader safely");
    Check([observer->batches count] == 0 && observer->completions == 0, @"closed picker receives no late callback");
    [observer release];

    printf("%lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
    [pool drain];
    return failures == 0 ? 0 : 1;
}
