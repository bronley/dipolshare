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
- (void)dealloc {
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

    [observer release];
    [writtenData release];
    printf("%lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
    [pool drain];
    return failures == 0 ? 0 : 1;
}
