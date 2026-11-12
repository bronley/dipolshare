#import <Foundation/Foundation.h>

@class UpdateChecker;
@protocol UpdateCheckerDelegate <NSObject>
- (void)updateChecker:(UpdateChecker *)checker foundVersion:(NSString *)version;
@end

@interface UpdateChecker : NSObject {
    NSURLConnection *_connection;
    NSMutableData *_responseData;
    NSTimer *_timeoutTimer;
    NSURL *_manifestURL;
    NSString *_installedVersion;
    NSString *_systemVersion;
    NSUserDefaults *_defaults;
    NSDate *_lastAttempt;
    id<UpdateCheckerDelegate> _delegate;
}
@property(nonatomic, assign) id<UpdateCheckerDelegate> delegate;
- (id)initWithURL:(NSURL *)url installedVersion:(NSString *)installed systemVersion:(NSString *)system
        defaults:(NSUserDefaults *)defaults;
- (void)check;
- (void)cancel;
- (void)dismissVersion:(NSString *)version;
- (void)remindLaterForVersion:(NSString *)version;
@end
