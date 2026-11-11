#import <Foundation/Foundation.h>
#import <Security/Security.h>

SecCertificateRef CreateDeviceCertificate(NSData *publicKeyData, SecKeyRef privateKey,
                                                   NSString **errorMessage);
NSData *SHA256DigestInfo(NSData *data);
NSString *CertificateFingerprint(SecCertificateRef certificate);
NSString *SecurityErrorDescription(OSStatus status);
