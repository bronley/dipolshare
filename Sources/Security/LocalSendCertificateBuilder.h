#import <Foundation/Foundation.h>
#import <Security/Security.h>

SecCertificateRef LocalSendCreateDeviceCertificate(NSData *publicKeyData, SecKeyRef privateKey,
                                                   NSString **errorMessage);
NSData *LocalSendSHA256DigestInfo(NSData *data);
NSString *LocalSendCertificateFingerprint(SecCertificateRef certificate);
NSString *LocalSendSecurityErrorDescription(OSStatus status);
