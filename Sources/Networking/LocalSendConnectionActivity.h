#import <Foundation/Foundation.h>

@interface LocalSendConnectionActivity : NSObject {
    NSString *_label;
    NSString *_stage;
    NSString *_longestStage;
    NSTimeInterval _startedAt;
    NSTimeInterval _stageStartedAt;
    NSTimeInterval _longestDuration;
    BOOL _finished;
    BOOL _cancelled;
}
- (id)initWithLabel:(NSString *)label;
- (void)setStage:(NSString *)stage;
- (NSString *)stage;
- (NSString *)diagnosticStatus;
- (void)cancel;
- (BOOL)isCancelled;
- (void)finishWithError:(NSString *)error;
+ (NSString *)diagnostics;
@end
