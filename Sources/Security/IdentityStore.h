#import <Foundation/Foundation.h>
#import <Security/Security.h>

extern NSString *const IdentityKeychainLabel;

typedef enum {
    CertificateDateStatusUnavailable = 0,
    CertificateDateStatusValid,
    CertificateDateStatusExpired,
    CertificateDateStatusNotYetValid,
    CertificateDateStatusClockIncorrect,
    CertificateDateStatusInvalid
} CertificateDateStatus;

@interface IdentityStore : NSObject
+ (SecIdentityRef)copyIdentityWithFingerprint:(NSString **)fingerprint error:(NSString **)errorMessage;
+ (SecIdentityRef)copyIdentityWithFingerprint:(NSString **)fingerprint
                                        error:(NSString **)errorMessage
                                   willCreate:(void (^)(void))willCreate;
+ (SecIdentityRef)regenerateIdentityWithFingerprint:(NSString **)fingerprint
                                              error:(NSString **)errorMessage;
+ (CertificateDateStatus)certificateDateStatusForIdentity:(SecIdentityRef)identity;
@end
