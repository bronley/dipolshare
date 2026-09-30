#import "LocalSendConnectionActivity.h"

static NSMutableSet *LocalSendActiveConnections;
static NSMutableArray *LocalSendRecentConnectionFailures;

@implementation LocalSendConnectionActivity
- (id)initWithLabel:(NSString *)label {
    if ((self = [super init])) {
        _label = [label copy];
        _stage = [@"Waiting for worker" copy];
        _startedAt = _stageStartedAt = [NSDate timeIntervalSinceReferenceDate];
        @synchronized([LocalSendConnectionActivity class]) {
            if (LocalSendActiveConnections == nil) {
                LocalSendActiveConnections = [[NSMutableSet alloc] init];
                LocalSendRecentConnectionFailures = [[NSMutableArray alloc] init];
            }
            [LocalSendActiveConnections addObject:self];
        }
    }
    return self;
}
- (void)setStage:(NSString *)stage {
    @synchronized([LocalSendConnectionActivity class]) {
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
    @synchronized([LocalSendConnectionActivity class]) {
        return [[_stage retain] autorelease];
    }
}
- (NSString *)diagnosticStatus {
    @synchronized([LocalSendConnectionActivity class]) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        return [NSString stringWithFormat:@"%@: %@%@ (%.1fs; total %.1fs)%@", _label,
            _cancelled ? @"Cancelling; " : @"", _stage,
            now - _stageStartedAt, now - _startedAt,
            _longestDuration >= 1.0 ? [NSString stringWithFormat:@"; slowest completed: %@ %.1fs",
                                       _longestStage, _longestDuration] : @""];
    }
}
- (void)cancel {
    @synchronized([LocalSendConnectionActivity class]) {
        _cancelled = YES;
    }
}
- (BOOL)isCancelled {
    @synchronized([LocalSendConnectionActivity class]) {
        return _cancelled;
    }
}
- (void)finishWithError:(NSString *)error {
    @synchronized([LocalSendConnectionActivity class]) {
        if (_finished) return;
        if (error != nil) {
            [LocalSendRecentConnectionFailures addObject:
                [NSString stringWithFormat:@"%@ — %@", [self diagnosticStatus], error]];
            if ([LocalSendRecentConnectionFailures count] > 4) {
                [LocalSendRecentConnectionFailures removeObjectAtIndex:0];
            }
        }
        _finished = YES;
        [LocalSendActiveConnections removeObject:self];
    }
}
+ (NSString *)diagnostics {
    @synchronized([LocalSendConnectionActivity class]) {
        NSMutableArray *lines = [NSMutableArray array];
        [lines addObject:[NSString stringWithFormat:@"Active network workers: %lu",
                          (unsigned long)[LocalSendActiveConnections count]]];
        for (LocalSendConnectionActivity *activity in LocalSendActiveConnections) {
            [lines addObject:[activity diagnosticStatus]];
        }
        if ([LocalSendRecentConnectionFailures count] > 0) {
            [lines addObject:@"Recent connection errors:"];
            [lines addObjectsFromArray:LocalSendRecentConnectionFailures];
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
