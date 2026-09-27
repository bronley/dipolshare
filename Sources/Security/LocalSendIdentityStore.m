#import "LocalSendIdentityStore.h"
#import "LocalSendCertificateBuilder.h"
#import <openssl/x509.h>

NSString *const LocalSendIdentityKeychainLabel = @"LocalSend iOS 5 mTLS v6";

static NSString *const IdentityFingerprintDefaultsKey = @"LocalSendClientIdentityFingerprint";
static NSString *const IdentityVersionDefaultsKey = @"LocalSendClientIdentityVersion";
static const NSInteger IdentityVersion = 6;

static SecIdentityRef CopyIdentityWithLabel(OSStatus *status) {
    // iOS 5–6 can otherwise match the certificate to its public key.
    NSDictionary *query = [NSDictionary
        dictionaryWithObjectsAndKeys:(id)kSecClassIdentity, (id)kSecClass, (id)kSecAttrKeyClassPrivate,
                                     (id)kSecAttrKeyClass, LocalSendIdentityKeychainLabel, (id)kSecAttrLabel,
                                     (id)kCFBooleanTrue, (id)kSecReturnRef, (id)kSecMatchLimitOne,
                                     (id)kSecMatchLimit, nil];
    SecIdentityRef identity = NULL;
    *status = SecItemCopyMatching((CFDictionaryRef)query, (CFTypeRef *)&identity);
    return identity;
}

static SecIdentityRef CopyIdentityMatchingFingerprint(NSString *wantedFingerprint) {
    if ([wantedFingerprint length] != 64) {
        return NULL;
    }

    NSDictionary *query = [NSDictionary
        dictionaryWithObjectsAndKeys:(id)kSecClassIdentity, (id)kSecClass, (id)kSecAttrKeyClassPrivate,
                                     (id)kSecAttrKeyClass, (id)kCFBooleanTrue, (id)kSecReturnRef,
                                     (id)kSecMatchLimitAll, (id)kSecMatchLimit, nil];
    CFTypeRef results = NULL;
    OSStatus status = SecItemCopyMatching((CFDictionaryRef)query, &results);
    if (status != errSecSuccess || results == NULL) {
        if (results != NULL) {
            CFRelease(results);
        }
        return NULL;
    }

    SecIdentityRef matchingIdentity = NULL;
    for (id result in (NSArray *)results) {
        SecIdentityRef candidate = (SecIdentityRef)result;
        SecCertificateRef certificate = NULL;
        if (SecIdentityCopyCertificate(candidate, &certificate) != errSecSuccess) {
            continue;
        }
        NSString *fingerprint = LocalSendCertificateFingerprint(certificate);
        CFRelease(certificate);
        if (fingerprint != nil && [wantedFingerprint caseInsensitiveCompare:fingerprint] == NSOrderedSame) {
            matchingIdentity = (SecIdentityRef)CFRetain(candidate);
            break;
        }
    }
    CFRelease(results);
    return matchingIdentity;
}

static SecIdentityRef CopyIdentityWithSavedFingerprint(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults integerForKey:IdentityVersionDefaultsKey] != IdentityVersion) {
        return NULL;
    }
    return CopyIdentityMatchingFingerprint([defaults stringForKey:IdentityFingerprintDefaultsKey]);
}

static BOOL GeneratePermanentKeyPair(NSData *applicationTag, SecKeyRef *publicKey, SecKeyRef *privateKey,
                                     NSString **errorMessage) {
    NSDictionary *publicAttributes =
        [NSDictionary dictionaryWithObjectsAndKeys:(id)kCFBooleanTrue, (id)kSecAttrIsPermanent,
                                                   applicationTag, (id)kSecAttrApplicationTag,
                                                   LocalSendIdentityKeychainLabel, (id)kSecAttrLabel, nil];
    NSDictionary *privateAttributes = [NSDictionary
        dictionaryWithObjectsAndKeys:(id)kCFBooleanTrue, (id)kSecAttrIsPermanent, (id)kCFBooleanTrue,
                                     (id)kSecAttrCanSign, applicationTag, (id)kSecAttrApplicationTag,
                                     LocalSendIdentityKeychainLabel, (id)kSecAttrLabel, nil];
    NSDictionary *parameters =
        [NSDictionary dictionaryWithObjectsAndKeys:(id)kSecAttrKeyTypeRSA, (id)kSecAttrKeyType,
                                                   [NSNumber numberWithInt:2048], (id)kSecAttrKeySizeInBits,
                                                   publicAttributes, (id)kSecPublicKeyAttrs,
                                                   privateAttributes, (id)kSecPrivateKeyAttrs, nil];
    OSStatus status = SecKeyGeneratePair((CFDictionaryRef)parameters, publicKey, privateKey);
    if (status != errSecSuccess) {
        if (errorMessage != NULL) {
            *errorMessage =
                [NSString stringWithFormat:@"Could not generate the RSA-2048 client key pair (%@).",
                                           LocalSendSecurityErrorDescription(status)];
        }
        return NO;
    }
    return YES;
}

static CFDataRef CopyPublicKeyData(NSData *applicationTag, NSString **errorMessage) {
    NSDictionary *query = [NSDictionary
        dictionaryWithObjectsAndKeys:(id)kSecClassKey, (id)kSecClass, applicationTag,
                                     (id)kSecAttrApplicationTag, (id)kSecAttrKeyClassPublic,
                                     (id)kSecAttrKeyClass, (id)kCFBooleanTrue, (id)kSecReturnData,
                                     (id)kSecMatchLimitOne, (id)kSecMatchLimit, nil];
    CFDataRef publicKeyData = NULL;
    OSStatus status = SecItemCopyMatching((CFDictionaryRef)query, (CFTypeRef *)&publicKeyData);
    if (status != errSecSuccess || publicKeyData == NULL) {
        if (publicKeyData != NULL) {
            CFRelease(publicKeyData);
        }
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"Could not export the generated public key (%@).",
                                                       LocalSendSecurityErrorDescription(status)];
        }
        return NULL;
    }
    return publicKeyData;
}

static BOOL StoreCertificate(SecCertificateRef certificate, NSString **errorMessage) {
    NSDictionary *item =
        [NSDictionary dictionaryWithObjectsAndKeys:(id)kSecClassCertificate, (id)kSecClass, (id)certificate,
                                                   (id)kSecValueRef, LocalSendIdentityKeychainLabel,
                                                   (id)kSecAttrLabel, nil];
    OSStatus status = SecItemAdd((CFDictionaryRef)item, NULL);
    if (status != errSecSuccess && status != errSecDuplicateItem) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"Could not store the client certificate (%@).",
                                                       LocalSendSecurityErrorDescription(status)];
        }
        return NO;
    }
    return YES;
}

static SecIdentityRef CreateIdentity(NSString **fingerprint, NSString **errorMessage) {
    NSString *uniqueTag = [NSString
        stringWithFormat:@"com.localsend.ios5.client.%@", [[NSProcessInfo processInfo] globallyUniqueString]];
    NSData *applicationTag = [uniqueTag dataUsingEncoding:NSUTF8StringEncoding];
    SecKeyRef publicKey = NULL;
    SecKeyRef privateKey = NULL;
    if (!GeneratePermanentKeyPair(applicationTag, &publicKey, &privateKey, errorMessage)) {
        return NULL;
    }

    CFDataRef publicKeyData = CopyPublicKeyData(applicationTag, errorMessage);
    CFRelease(publicKey);
    if (publicKeyData == NULL) {
        CFRelease(privateKey);
        return NULL;
    }
    SecCertificateRef certificate =
        LocalSendCreateDeviceCertificate((NSData *)publicKeyData, privateKey, errorMessage);
    CFRelease(publicKeyData);
    if (certificate == NULL) {
        CFRelease(privateKey);
        return NULL;
    }
    if (!StoreCertificate(certificate, errorMessage)) {
        CFRelease(certificate);
        CFRelease(privateKey);
        return NULL;
    }

    NSString *newFingerprint = LocalSendCertificateFingerprint(certificate);
    SecIdentityRef identity = CopyIdentityMatchingFingerprint(newFingerprint);
    CFRelease(privateKey);
    if (identity == NULL) {
        CFRelease(certificate);
        if (errorMessage != NULL) {
            *errorMessage = @"The new certificate and private key did not form a Keychain identity.";
        }
        return NULL;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:newFingerprint forKey:IdentityFingerprintDefaultsKey];
    [defaults setInteger:IdentityVersion forKey:IdentityVersionDefaultsKey];
    [defaults synchronize];
    if (fingerprint != NULL) {
        *fingerprint = newFingerprint;
    }
    CFRelease(certificate);
    return identity;
}

@implementation LocalSendIdentityStore

+ (LocalSendCertificateDateStatus)certificateDateStatusForIdentity:(SecIdentityRef)identity {
    if (identity == NULL) {
        return LocalSendCertificateDateStatusUnavailable;
    }
    SecCertificateRef certificate = NULL;
    if (SecIdentityCopyCertificate(identity, &certificate) != errSecSuccess || certificate == NULL) {
        return LocalSendCertificateDateStatusInvalid;
    }
    CFDataRef der = SecCertificateCopyData(certificate);
    CFRelease(certificate);
    if (der == NULL) {
        return LocalSendCertificateDateStatusInvalid;
    }
    const unsigned char *cursor = CFDataGetBytePtr(der);
    X509 *x509 = d2i_X509(NULL, &cursor, (long)CFDataGetLength(der));
    CFRelease(der);
    if (x509 == NULL) {
        return LocalSendCertificateDateStatusInvalid;
    }

    const ASN1_TIME *notBefore = X509_get0_notBefore(x509);
    const ASN1_TIME *notAfter = X509_get0_notAfter(x509);
    // This app was first built in 2026. A certificate already expired before 2026
    // cannot be useful even if the device clock has since been set back to 1970.
    time_t earliestPlausibleTime = 1767225600; // 2026-01-01 UTC
    int expiryAtRelease = X509_cmp_time(notAfter, &earliestPlausibleTime);
    int startAtCurrentTime = X509_cmp_current_time(notBefore);
    int expiryAtCurrentTime = X509_cmp_current_time(notAfter);
    X509_free(x509);
    if (expiryAtRelease == 0 || startAtCurrentTime == 0 || expiryAtCurrentTime == 0) {
        return LocalSendCertificateDateStatusInvalid;
    }
    if ([[NSDate date] timeIntervalSince1970] < (NSTimeInterval)earliestPlausibleTime) {
        return LocalSendCertificateDateStatusClockIncorrect;
    }
    if (expiryAtRelease < 0 || expiryAtCurrentTime < 0) {
        return LocalSendCertificateDateStatusExpired;
    }
    if (startAtCurrentTime > 0) {
        return LocalSendCertificateDateStatusNotYetValid;
    }
    return LocalSendCertificateDateStatusValid;
}

+ (SecIdentityRef)copyIdentityWithFingerprint:(NSString **)fingerprint error:(NSString **)errorMessage {
    return [self copyIdentityWithFingerprint:fingerprint error:errorMessage willCreate:nil];
}

+ (SecIdentityRef)copyIdentityWithFingerprint:(NSString **)fingerprint
                                        error:(NSString **)errorMessage
                                   willCreate:(void (^)(void))willCreate {
    @synchronized(self) {
        OSStatus status;
        SecIdentityRef identity = CopyIdentityWithSavedFingerprint();
        if (identity == NULL) {
            identity = CopyIdentityWithLabel(&status);
        }
        if (identity == NULL) {
            if (willCreate != nil) {
                willCreate();
            }
            identity = CreateIdentity(NULL, errorMessage);
        }
        if (identity == NULL) {
            return NULL;
        }

        SecCertificateRef certificate = NULL;
        status = SecIdentityCopyCertificate(identity, &certificate);
        if (status != errSecSuccess || certificate == NULL) {
            CFRelease(identity);
            if (errorMessage != NULL) {
                *errorMessage = [NSString stringWithFormat:@"Stored client identity has no certificate (%@).",
                                                           LocalSendSecurityErrorDescription(status)];
            }
            return NULL;
        }

        NSString *certificateFingerprint = LocalSendCertificateFingerprint(certificate);
        CFRelease(certificate);
        if ([certificateFingerprint length] != 64) {
            CFRelease(identity);
            if (errorMessage != NULL) {
                *errorMessage = @"The client certificate fingerprint could not be read.";
            }
            return NULL;
        }
        if (fingerprint != NULL) {
            *fingerprint = certificateFingerprint;
        }
        return identity;
    }
}

+ (SecIdentityRef)regenerateIdentityWithFingerprint:(NSString **)fingerprint
                                              error:(NSString **)errorMessage {
    @synchronized(self) {
        return CreateIdentity(fingerprint, errorMessage);
    }
}

@end
