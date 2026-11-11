#import <Foundation/Foundation.h>

@interface Sounds : NSObject
+ (BOOL)soundEffectsEnabled;
+ (void)setSoundEffectsEnabled:(BOOL)enabled;
+ (void)playIncomingTransfer;
+ (void)playOutgoingTransferComplete;
@end
