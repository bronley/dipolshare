#import "LocalSendSounds.h"
#import <AudioToolbox/AudioToolbox.h>

@implementation LocalSendSounds

+ (void)playResource:(NSString *)name soundID:(SystemSoundID *)soundID {
    @synchronized(self) {
        if (*soundID == 0) {
            NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:@"caf"];
            if (url == nil) {
                return;
            }
            OSStatus status = AudioServicesCreateSystemSoundID((CFURLRef)url, soundID);
            if (status != noErr) {
                NSLog(@"LocalSend could not load %@.caf (OSStatus %ld)", name, (long)status);
                return;
            }
        }
        AudioServicesPlaySystemSound(*soundID);
    }
}

+ (void)playIncomingTransfer {
    static SystemSoundID soundID = 0;
    [self playResource:@"IncomingTransfer" soundID:&soundID];
}

+ (void)playOutgoingTransferComplete {
    static SystemSoundID soundID = 0;
    [self playResource:@"OutgoingTransferComplete" soundID:&soundID];
}

@end
