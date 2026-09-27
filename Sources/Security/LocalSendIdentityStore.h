#import <Foundation/Foundation.h>
#import <Security/Security.h>

extern NSString *const LocalSendIdentityKeychainLabel;

typedef enum {
    LocalSendCertificateDateStatusUnavailable = 0,
    LocalSendCertificateDateStatusValid,
    LocalSendCertificateDateStatusExpired,
    LocalSendCertificateDateStatusNotYetValid,
    LocalSendCertificateDateStatusClockIncorrect,
    LocalSendCertificateDateStatusInvalid
} LocalSendCertificateDateStatus;

@interface LocalSendIdentityStore : NSObject
+ (SecIdentityRef)copyIdentityWithFingerprint:(NSString **)fingerprint error:(NSString **)errorMessage;
+ (SecIdentityRef)copyIdentityWithFingerprint:(NSString **)fingerprint
                                        error:(NSString **)errorMessage
                                   willCreate:(void (^)(void))willCreate;
+ (SecIdentityRef)regenerateIdentityWithFingerprint:(NSString **)fingerprint
                                              error:(NSString **)errorMessage;
+ (LocalSendCertificateDateStatus)certificateDateStatusForIdentity:(SecIdentityRef)identity;
@end
