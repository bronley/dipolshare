#import "Sounds.h"
#import <AudioToolbox/AudioToolbox.h>

static NSString *const SoundEffectsEnabledKey = @"LocalSendSoundEffectsEnabled";

@implementation Sounds

+ (BOOL)soundEffectsEnabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:SoundEffectsEnabledKey] == nil ||
           [defaults boolForKey:SoundEffectsEnabledKey];
}

+ (void)setSoundEffectsEnabled:(BOOL)enabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:SoundEffectsEnabledKey];
    [defaults synchronize];
}

+ (void)playResource:(NSString *)name soundID:(SystemSoundID *)soundID {
    @synchronized(self) {
        if (![self soundEffectsEnabled]) {
            return;
        }
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
