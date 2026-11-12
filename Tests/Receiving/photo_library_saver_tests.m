#import "PhotoLibrarySaver.h"
#import <AssetsLibrary/AssetsLibrary.h>

static NSUInteger checks, failures, writes, destroyedSavers;
static NSData *writtenData;
static BOOL wroteInBackground;
static void (^pendingCompletion)(NSURL *, NSError *);

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

@implementation ALAssetsLibrary
- (void)writeImageDataToSavedPhotosAlbum:(NSData *)data
                              metadata:(NSDictionary *)metadata
                       completionBlock:(void (^)(NSURL *, NSError *))completion {
    @synchronized([ALAssetsLibrary class]) {
        writes++;
        [writtenData release];
        writtenData = [data copy];
        wroteInBackground = ![NSThread isMainThread];
        pendingCompletion = [completion copy];
    }
}

+ (void)complete:(NSArray *)result {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    void (^completion)(NSURL *, NSError *);
    @synchronized(self) {
        completion = pendingCompletion;
        pendingCompletion = nil;
    }
    id url = [result objectAtIndex:0], error = [result objectAtIndex:1];
    completion(url == [NSNull null] ? nil : url, error == [NSNull null] ? nil : error);
    [completion release];
    [pool drain];
}
@end

static BOOL HasPendingWrite(void) {
    @synchronized([ALAssetsLibrary class]) {
        return pendingCompletion != nil;
    }
}

static void Finish(BOOL success, NSError *error) {
    NSArray *result = [NSArray arrayWithObjects:
        success ? (id)[NSURL URLWithString:@"assets-library://saved-photo"] : (id)[NSNull null],
        error ?: (id)[NSNull null], nil];
    [NSThread detachNewThreadSelector:@selector(complete:) toTarget:[ALAssetsLibrary class] withObject:result];
}

@interface SaveObserver : NSObject <PhotoLibrarySaverDelegate> {
@public
    NSUInteger calls;
    NSString *message;
    NSUInteger batchCalls, savedCount, progressCalls;
    NSArray *failedPaths;

}
@end
@implementation SaveObserver
- (void)photoLibrarySaver:(PhotoLibrarySaver *)saver didFinishWithErrorMessage:(NSString *)errorMessage {
    Check([NSThread isMainThread], @"completion reaches the delegate on the main thread");
    Check(!saver.saving, @"completion clears the busy state before notifying the delegate");
    calls++;
    [message release];
    message = [errorMessage copy];
}
- (void)photoLibrarySaver:(PhotoLibrarySaver *)saver didCompletePhotos:(NSUInteger)completed total:(NSUInteger)total {
    Check([NSThread isMainThread] && saver.saving, @"batch progress stays on main and remains busy");
    Check(completed > 0 && completed <= total, @"batch progress stays within its total");
    progressCalls++;
}
- (void)photoLibrarySaver:(PhotoLibrarySaver *)saver didFinishBatchWithSavedCount:(NSUInteger)count
             failedPaths:(NSArray *)paths errorMessage:(NSString *)errorMessage {
    Check([NSThread isMainThread] && !saver.saving, @"batch completion reaches main after clearing busy state");
    batchCalls++;
    savedCount = count;
    [failedPaths release];
    failedPaths = [paths copy];
    [message release];
    message = [errorMessage copy];
}
- (void)dealloc {
    [failedPaths release];
    [message release];
    [super dealloc];
}
@end

@interface TrackedPhotoSaver : PhotoLibrarySaver
@end
@implementation TrackedPhotoSaver
- (void)dealloc {
    destroyedSavers++;
    [super dealloc];
}
@end

int main(int argc, const char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *directory = [NSString stringWithUTF8String:argv[1]];
    NSString *photo = [directory stringByAppendingPathComponent:@"photo.jpg"];
    NSData *original = [@"original photo bytes and metadata" dataUsingEncoding:NSUTF8StringEncoding];
    [original writeToFile:photo atomically:YES];
    SaveObserver *observer = [[SaveObserver alloc] init];
    PhotoLibrarySaver *saver = [[PhotoLibrarySaver alloc] init];
    saver.delegate = observer;

    Check([saver savePhotoAtPath:photo] && saver.saving, @"save starts and immediately becomes busy");
    Check(![saver savePhotoAtPath:photo], @"a second save is rejected while busy");
    if (!WaitFor(^BOOL { return HasPendingWrite(); })) return 2;
    @synchronized([ALAssetsLibrary class]) {
        Check(wroteInBackground && [writtenData isEqualToData:original],
              @"original bytes are passed to the photo library in the background");
    }
    Finish(YES, nil);
    Check(WaitFor(^BOOL { return observer->calls == 1; }) && observer->message == nil,
          @"successful save reports success");

    Check([saver savePhotoAtPath:photo], @"saver can be reused after completion");
    if (!WaitFor(^BOOL { return HasPendingWrite(); })) return 2;
    Finish(NO, [NSError errorWithDomain:@"Test" code:1 userInfo:
        [NSDictionary dictionaryWithObject:@"Photo access denied" forKey:NSLocalizedDescriptionKey]]);
    Check(WaitFor(^BOOL { return observer->calls == 2; }) &&
          [observer->message isEqualToString:@"Photo access denied"], @"library errors reach the delegate");

    [saver savePhotoAtPath:photo];
    if (!WaitFor(^BOOL { return HasPendingWrite(); })) return 2;
    Finish(NO, nil);
    Check(WaitFor(^BOOL { return observer->calls == 3; }) && observer->message != nil,
          @"missing asset URL is a failure even without a library error");

    NSString *missing = [directory stringByAppendingPathComponent:@"missing.jpg"];
    NSString *empty = [directory stringByAppendingPathComponent:@"empty.jpg"];
    NSString *large = [directory stringByAppendingPathComponent:@"large.jpg"];
    [[NSData data] writeToFile:empty atomically:YES];
    [[NSData data] writeToFile:large atomically:YES];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:large];
    [handle truncateFileAtOffset:64ULL * 1024ULL * 1024ULL + 1];
    [handle closeFile];
    NSArray *invalidPaths = [NSArray arrayWithObjects:missing, empty, large, nil];
    NSArray *errors = [NSArray arrayWithObjects:@"This file is no longer available.",
        @"The photo could not be read.", @"This photo is too large to save on this device (64 MB limit).", nil];
    for (NSUInteger i = 0; i < [invalidPaths count]; i++) {
        NSUInteger expectedCalls = observer->calls + 1;
        [saver savePhotoAtPath:[invalidPaths objectAtIndex:i]];
        Check(WaitFor(^BOOL { return observer->calls == expectedCalls; }) &&
              [observer->message isEqualToString:[errors objectAtIndex:i]],
              @"invalid file reports the existing validation message");
    }
    Check(writes == 3, @"invalid files never reach the photo library");
    Check(![saver savePhotosAtPaths:[NSArray array]] && !saver.saving, @"empty batch never starts");
    NSMutableArray *batch = [NSMutableArray arrayWithObjects:photo, missing, photo, photo, nil];
    NSUInteger singleCalls = observer->calls;
    Check([saver savePhotosAtPaths:batch] && saver.saving, @"batch starts and immediately becomes busy");
    [batch removeAllObjects];
    Check(![saver savePhotoAtPath:photo] && ![saver savePhotosAtPaths:[NSArray arrayWithObject:photo]],
          @"single and batch saves cannot interrupt a running batch");
    if (!WaitFor(^BOOL { return HasPendingWrite(); })) return 2;
    Check(writes == 4, @"only the first photo is submitted before its callback");
    Finish(YES, nil);
    if (!WaitFor(^BOOL { return HasPendingWrite() && observer->progressCalls == 2; })) return 2;
    Check(writes == 5 && observer->batchCalls == 0, @"missing file is skipped and later photos still save");
    Finish(NO, [NSError errorWithDomain:@"Test" code:2 userInfo:
        [NSDictionary dictionaryWithObject:@"Library full" forKey:NSLocalizedDescriptionKey]]);
    if (!WaitFor(^BOOL { return HasPendingWrite() && observer->progressCalls == 3; })) return 2;
    Finish(YES, nil);
    Check(WaitFor(^BOOL { return observer->batchCalls == 1; }) && observer->savedCount == 2 &&
          [observer->failedPaths isEqualToArray:[NSArray arrayWithObjects:missing, photo, nil]],
          @"batch snapshots input and reports exact successes and failed paths");
    Check(observer->progressCalls == 4 && observer->calls == singleCalls,
          @"each batch photo reports progress without single-save alerts");
    Check([observer->message isEqualToString:@"This file is no longer available."],
          @"batch keeps the first error for the summary");
    Check([saver savePhotosAtPaths:[NSArray arrayWithObject:photo]], @"completed saver accepts another batch");
    if (!WaitFor(^BOOL { return HasPendingWrite(); })) return 2;
    Finish(YES, nil);
    Check(WaitFor(^BOOL { return observer->batchCalls == 2; }) && observer->savedCount == 1 &&
          [observer->failedPaths count] == 0 && observer->message == nil,
          @"successful retry clears previous errors and counts");
    [saver savePhotosAtPaths:invalidPaths];
    Check(WaitFor(^BOOL { return observer->batchCalls == 3; }) && observer->savedCount == 0 &&
          [observer->failedPaths isEqualToArray:invalidPaths], @"all-invalid batch finishes with all failures");
    saver.delegate = nil;
    [saver release];

    TrackedPhotoSaver *detached = [[TrackedPhotoSaver alloc] init];
    detached.delegate = observer;
    [detached savePhotoAtPath:photo];
    if (!WaitFor(^BOOL { return HasPendingWrite(); })) return 2;
    detached.delegate = nil;
    [detached release];
    Check(destroyedSavers == 0, @"pending save stays alive after its screen releases it");
    NSUInteger previousCalls = observer->calls;
    Finish(YES, nil);
    Check(WaitFor(^BOOL { return destroyedSavers == 1; }), @"completed detached save is released");
    Check(observer->calls == previousCalls, @"detached screen receives no late callback");

    detached = [[TrackedPhotoSaver alloc] init];
    detached.delegate = observer;
    [detached savePhotosAtPaths:[NSArray arrayWithObjects:photo, photo, nil]];
    if (!WaitFor(^BOOL { return HasPendingWrite(); })) return 2;
    detached.delegate = nil;
    [detached release];
    __block NSUInteger lastWrites;
    @synchronized([ALAssetsLibrary class]) { lastWrites = writes; }
    Finish(YES, nil);
    if (!WaitFor(^BOOL {
        @synchronized([ALAssetsLibrary class]) {
            return writes == lastWrites + 1 && pendingCompletion != nil;
        }
    })) return 2;
    Check(destroyedSavers == 1, @"detached batch survives until its final photo");
    Finish(YES, nil);
    Check(WaitFor(^BOOL { return destroyedSavers == 2; }), @"detached batch releases after its final callback");
    Check(observer->batchCalls == 3, @"detached batch never calls its former delegate");

    [observer release];
    [writtenData release];
    printf("%lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
    [pool drain];
    return failures == 0 ? 0 : 1;
}
