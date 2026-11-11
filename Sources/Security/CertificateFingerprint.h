#import <Foundation/Foundation.h>

BOOL PeerFingerprintMatches(NSString *expectedFingerprint, NSString *actualFingerprint,
                                     BOOL allowsUnknownDiscoveryPeer);
