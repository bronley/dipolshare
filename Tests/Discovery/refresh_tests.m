#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "LocalSendDiscovery.h"
#import "LocalSendReceiver.h"
#import "LocalSendReceiveServer.h"
#import <float.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <unistd.h>

static NSMutableSet *runningWorkers;
static NSUInteger cancellations, receiverStops;
static unsigned checks;
#define CHECK(condition) do { checks++; if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); exit(1); } } while (0)

@implementation LocalSendDiscoveryProbe
- (id)initWithDelegate:(id<LocalSendDiscoveryProbeDelegate>)delegate endpoint:(NSDictionary *)value
            generation:(NSUInteger)valueGeneration {
    if ((self = [super init])) {
        endpoint = [value copy]; generation = valueGeneration; _delegate = delegate;
        startedAt = [NSDate timeIntervalSinceReferenceDate];
    }
    return self;
}
- (NSDictionary *)endpoint { return endpoint; }
- (NSUInteger)generation { return generation; }
- (NSTimeInterval)startedAt { return startedAt; }
- (NSString *)failureMessage { return @"Simulated timeout"; }
- (BOOL)hasRunningWorker { return [runningWorkers containsObject:self]; }
- (void)startWithIdentity:(SecIdentityRef)identity info:(NSDictionary *)info {
    (void)identity; (void)info; [runningWorkers addObject:self];
}
- (void)invalidate { _delegate = nil; cancellations++; }
- (void)dealloc { [endpoint release]; [super dealloc]; }
@end

NSString *const LocalSendReceivePeerDidRegisterNotification = @"TestPeerRegistered";
@implementation LocalSendReceiver
+ (LocalSendReceiver *)sharedReceiver {
    static LocalSendReceiver *receiver;
    if (receiver == nil) receiver = [self new];
    return receiver;
}
- (void)stop { receiverStops++; }
@end
@implementation LocalSendReceiveServer
@end
@implementation LocalSendIdentityStore
@end
@implementation UIDevice
@end

@interface LocalSendDiscovery (SchedulerTests)
- (void)beginScan;
- (void)tick:(NSTimer *)timer;
- (void)enqueueProbe:(NSDictionary *)endpoint;
@end
@interface TestDiscovery : LocalSendDiscovery
- (void)activate;
- (void)advanceRefresh;
- (NSTimeInterval)refreshDeadline;
- (NSUInteger)generation;
- (NSUInteger)activeCount;
- (NSUInteger)retiringCount;
- (NSUInteger)pendingCount;
- (NSUInteger)announcements;
- (NSUInteger)failures;
- (NSArray *)active;
- (void)remember:(NSDictionary *)device;
- (void)addScanSocket:(int)fd;
- (BOOL)scanIsEmpty;
- (void)allowAnnouncement;
@end
@implementation TestDiscovery
- (void)activate {
    _running = YES;
    _lastInterfaceCheck = DBL_MAX;
    _lastTickAt = [NSDate timeIntervalSinceReferenceDate];
}
- (void)announce { _announcementsSent++; }
- (void)advanceRefresh { _refreshAt = 0; [self tick:nil]; }
- (NSTimeInterval)refreshDeadline { return _refreshAt; }
- (NSUInteger)generation { return _generation; }
- (NSUInteger)activeCount { return [_activeProbes count]; }
- (NSUInteger)retiringCount { return [_retiringProbes count]; }
- (NSUInteger)pendingCount { return [_pendingDiscoveryProbes count]; }
- (NSUInteger)announcements { return _announcementsSent; }
- (NSUInteger)failures { return _probeFailures; }
- (NSArray *)active { return [[_activeProbes copy] autorelease]; }
- (void)remember:(NSDictionary *)device {
    [_devicesByFingerprint setObject:device forKey:[device objectForKey:@"address"]];
}
- (void)addScanSocket:(int)fd {
    [_subnetScanSockets setObject:@{} forKey:[NSNumber numberWithInt:fd]];
    [_pendingSubnetAddresses addObject:@"192.0.2.200"];
}
- (BOOL)scanIsEmpty { return [_subnetScanSockets count] == 0 && [_pendingSubnetAddresses count] == 0; }
- (void)allowAnnouncement { _nextAnnouncementAt = 0; }
@end

static NSDictionary *Endpoint(unsigned n) {
    return @{ @"address": [NSString stringWithFormat:@"192.0.2.%u", n], @"port": @53317, @"protocol": @"https" };
}
int main(void) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    runningWorkers = [NSMutableSet new];
    TestDiscovery *discovery = [TestDiscovery new];
    [discovery activate];
    for (unsigned i = 1; i <= 2; i++) { [discovery remember:Endpoint(i)]; [discovery enqueueProbe:Endpoint(i)]; }
    [discovery enqueueProbe:Endpoint(3)];
    CHECK([discovery activeCount] == 2 && [discovery pendingCount] == 1);
    NSArray *old = [[discovery active] retain];
    int sockets[2]; CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    [discovery addScanSocket:sockets[0]];
    [discovery refresh];
    CHECK([discovery activeCount] == 0 && [discovery pendingCount] == 0);
    CHECK([discovery retiringCount] == 2 && cancellations == 2);
    CHECK(fcntl(sockets[0], F_GETFD) == -1 && [discovery scanIsEmpty]);
    close(sockets[1]);
    NSUInteger generation = [discovery generation];
    NSTimeInterval deadline = [discovery refreshDeadline];
    for (unsigned i = 0; i < 100; i++) [discovery refresh];
    CHECK([discovery generation] == generation && [discovery refreshDeadline] == deadline);
    CHECK(cancellations == 2 && [runningWorkers count] == 2);
    [discovery advanceRefresh];
    CHECK([discovery announcements] == 1);
    CHECK([discovery activeCount] == 0 && [discovery pendingCount] == 2);
    for (LocalSendDiscoveryProbe *probe in old) [discovery discoveryProbe:probe didCompleteWithMessage:nil];
    CHECK([discovery failures] == 0 && [[discovery devices] count] == 2);
    [runningWorkers removeObject:[old objectAtIndex:0]];
    [discovery tick:nil];
    CHECK([discovery retiringCount] == 1 && [discovery activeCount] == 1 && [runningWorkers count] == 2);
    [runningWorkers removeObject:[old objectAtIndex:1]];
    [discovery tick:nil];
    CHECK([discovery retiringCount] == 0 && [discovery activeCount] == 2);
    [old release];

    LocalSendDiscoveryProbe *timedOut = [[[discovery active] objectAtIndex:0] retain];
    [discovery enqueueProbe:Endpoint(4)];
    [discovery discoveryProbe:timedOut didCompleteWithMessage:nil];
    CHECK([discovery retiringCount] == 1 && [discovery activeCount] == 1 && [discovery pendingCount] == 1);
    [runningWorkers removeObject:timedOut];
    [timedOut release];
    [discovery tick:nil];
    CHECK([discovery activeCount] == 2 && [discovery pendingCount] == 0);

    for (unsigned round = 0; round < 20; round++) {
        NSArray *workers = [[runningWorkers allObjects] retain];
        for (unsigned tap = 0; tap < 20; tap++) [discovery refresh];
        [discovery advanceRefresh];
        CHECK([discovery activeCount] == 0 && [runningWorkers count] == 2);
        [runningWorkers minusSet:[NSSet setWithArray:workers]];
        [workers release];
        [discovery tick:nil];
        CHECK([discovery activeCount] == 2 && [runningWorkers count] == 2);
        CHECK([discovery announcements] == 1);
    }
    [discovery allowAnnouncement];
    [discovery tick:nil];
    CHECK([discovery announcements] == 2);
    CHECK(receiverStops == 0);
    [discovery stop];
    CHECK([discovery activeCount] == 0 && [discovery retiringCount] == 2);
    [discovery activate]; [discovery beginScan];
    CHECK([discovery activeCount] == 0 && [runningWorkers count] == 2);
    [runningWorkers removeAllObjects]; [discovery tick:nil];
    CHECK([discovery activeCount] == 2);
    [discovery stop]; [runningWorkers removeAllObjects];
    [discovery release]; [runningWorkers release];
    printf("%u refresh scheduler checks passed\n", checks);
    [pool drain];
    return 0;
}
