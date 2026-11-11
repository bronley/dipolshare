#import "ConnectionActivity.h"

static NSMutableSet *ActiveConnections;
static NSMutableArray *RecentConnectionFailures;

@implementation ConnectionActivity
- (id)initWithLabel:(NSString *)label {
    if ((self = [super init])) {
        _label = [label copy];
        _stage = [@"Waiting for worker" copy];
        _startedAt = _stageStartedAt = [NSDate timeIntervalSinceReferenceDate];
        @synchronized([ConnectionActivity class]) {
            if (ActiveConnections == nil) {
                ActiveConnections = [[NSMutableSet alloc] init];
                RecentConnectionFailures = [[NSMutableArray alloc] init];
            }
            [ActiveConnections addObject:self];
        }
    }
    return self;
}
- (void)setStage:(NSString *)stage {
    @synchronized([ConnectionActivity class]) {
        if (_finished || [_stage isEqual:stage]) return;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval elapsed = now - _stageStartedAt;
        if (elapsed > _longestDuration) {
            _longestDuration = elapsed;
            [_longestStage release];
            _longestStage = [_stage copy];
        }
        [_stage release];
        _stage = [stage copy];
        _stageStartedAt = now;
    }
}
- (NSString *)stage {
    @synchronized([ConnectionActivity class]) {
        return [[_stage retain] autorelease];
    }
}
- (NSString *)diagnosticStatus {
    @synchronized([ConnectionActivity class]) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        return [NSString stringWithFormat:@"%@: %@%@ (%.1fs; total %.1fs)%@", _label,
            _cancelled ? @"Cancelling; " : @"", _stage,
            now - _stageStartedAt, now - _startedAt,
            _longestDuration >= 1.0 ? [NSString stringWithFormat:@"; slowest completed: %@ %.1fs",
                                       _longestStage, _longestDuration] : @""];
    }
}
- (void)cancel {
    @synchronized([ConnectionActivity class]) {
        _cancelled = YES;
    }
}
- (BOOL)isCancelled {
    @synchronized([ConnectionActivity class]) {
        return _cancelled;
    }
}
- (void)finishWithError:(NSString *)error {
    @synchronized([ConnectionActivity class]) {
        if (_finished) return;
        if (error != nil) {
            [RecentConnectionFailures addObject:
                [NSString stringWithFormat:@"%@ — %@", [self diagnosticStatus], error]];
            if ([RecentConnectionFailures count] > 4) {
                [RecentConnectionFailures removeObjectAtIndex:0];
            }
        }
        _finished = YES;
        [ActiveConnections removeObject:self];
    }
}
+ (NSString *)diagnostics {
    @synchronized([ConnectionActivity class]) {
        NSMutableArray *lines = [NSMutableArray array];
        [lines addObject:[NSString stringWithFormat:@"Active network workers: %lu",
                          (unsigned long)[ActiveConnections count]]];
        for (ConnectionActivity *activity in ActiveConnections) {
            [lines addObject:[activity diagnosticStatus]];
        }
        if ([RecentConnectionFailures count] > 0) {
            [lines addObject:@"Recent connection errors:"];
            [lines addObjectsFromArray:RecentConnectionFailures];
        }
        return [lines componentsJoinedByString:@"\n"];
    }
}
- (void)dealloc {
    [_label release];
    [_stage release];
    [_longestStage release];
    [super dealloc];
}
@end
