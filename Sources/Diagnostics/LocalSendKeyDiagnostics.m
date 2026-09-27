#import "LocalSendKeyDiagnostics.h"
#import "LocalSendIdentityStore.h"
#import "LocalSendCertificateBuilder.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>

static SecKeyRef CopyDiagnosticCertificatePublicKey(SecCertificateRef certificate, NSMutableString *report) {
    if (certificate == NULL) {
        return NULL;
    }
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    SecTrustRef trust = NULL;
    OSStatus status =
        policy != NULL ? SecTrustCreateWithCertificates(certificate, policy, &trust) : errSecAllocate;
    if (policy != NULL) {
        CFRelease(policy);
    }
    if (status != errSecSuccess || trust == NULL) {
        [report appendFormat:@"Certificate public key: trust setup=%ld\n", (long)status];
        if (trust != NULL) {
            CFRelease(trust);
        }
        return NULL;
    }
    SecTrustResultType result = kSecTrustResultInvalid;
    status = SecTrustEvaluate(trust, &result);
    /* Trust failure is expected for this self-signed certificate.
     * Extracting the public key does not approve it for network use. */
    SecKeyRef key = SecTrustCopyPublicKey(trust);
    [report appendFormat:@"Certificate public key: evaluate=%ld, trust=%ld, extracted=%@\n", (long)status,
                         (long)result, key != NULL ? @"yes" : @"no"];
    CFRelease(trust);
    return key;
}

static void AppendKeyMetadata(NSMutableString *report, SecKeyRef key) {
    NSDictionary *query =
        [NSDictionary dictionaryWithObjectsAndKeys:(id)kSecClassKey, (id)kSecClass, (id)key, (id)kSecValueRef,
                                                   (id)kCFBooleanTrue, (id)kSecReturnAttributes, nil];
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result != NULL && CFGetTypeID(result) == CFDictionaryGetTypeID()) {
        NSDictionary *attributes = (NSDictionary *)result;
        id keyClass = [attributes objectForKey:(id)kSecAttrKeyClass];
        NSString *className = @"unknown";
        if ([keyClass isEqual:(id)kSecAttrKeyClassPrivate]) {
            className = @"private";
        } else if ([keyClass isEqual:(id)kSecAttrKeyClassPublic]) {
            className = @"public";
        }
        [report appendFormat:@"class=%@, bits=%@, canSign=%@; ", className,
                             [attributes objectForKey:(id)kSecAttrKeySizeInBits] ?: @"?",
                             [attributes objectForKey:(id)kSecAttrCanSign] ?: @"?"];
    } else {
        [report appendFormat:@"attributes=%ld; ", (long)status];
    }
    if (result != NULL) {
        CFRelease(result);
    }
}

static void AppendSigningProbe(NSMutableString *report, SecKeyRef signingKey, SecKeyRef certificatePublicKey,
                               NSData *digestInfo, BOOL certificateVerification) {
    if (signingKey == NULL || CFGetTypeID(signingKey) != SecKeyGetTypeID()) {
        [report appendString:@"No usable key reference.\n"];
        return;
    }
    AppendKeyMetadata(report, signingKey);
    size_t length = SecKeyGetBlockSize(signingKey);
    if (length == 0 || length > 16384) {
        [report appendFormat:@"invalid RSA block size=%lu\n", (unsigned long)length];
        return;
    }
    NSMutableData *signature = [NSMutableData dataWithLength:length];
    OSStatus signStatus = SecKeyRawSign(signingKey, kSecPaddingPKCS1, [digestInfo bytes], [digestInfo length],
                                        [signature mutableBytes], &length);
    [report appendFormat:@"sign=%ld", (long)signStatus];
    if (signStatus == errSecSuccess && length <= [signature length] && certificatePublicKey != NULL) {
        OSStatus verifyStatus = SecKeyRawVerify(certificatePublicKey, kSecPaddingPKCS1, [digestInfo bytes],
                                                [digestInfo length], [signature bytes], length);
        [report appendFormat:@", verify=%ld %@", (long)verifyStatus,
                             verifyStatus == errSecSuccess
                                 ? (certificateVerification ? @"PASS" : @"CONTROL OK")
                                 : @"FAIL"];
    } else if (signStatus == errSecSuccess) {
        [report appendString:@", verification unavailable (not a pass)"];
    } else {
        [report appendString:@" FAIL"];
    }
    [report appendString:@"\n"];
}

static void AppendIdentityProbe(NSMutableString *report, SecIdentityRef identity,
                                SecCertificateRef expectedCertificate, NSData *digestInfo) {
    if (identity == NULL || CFGetTypeID(identity) != SecIdentityGetTypeID()) {
        [report appendString:@"No usable identity reference.\n"];
        return;
    }
    SecCertificateRef certificate = NULL;
    SecKeyRef privateKey = NULL;
    OSStatus certificateStatus = SecIdentityCopyCertificate(identity, &certificate);
    OSStatus keyStatus = SecIdentityCopyPrivateKey(identity, &privateKey);
    [report
        appendFormat:@"CopyCertificate=%ld, CopyPrivateKey=%ld\n", (long)certificateStatus, (long)keyStatus];
    BOOL matchesBaseline = YES;
    if (certificate != NULL && expectedCertificate != NULL) {
        CFDataRef actual = SecCertificateCopyData(certificate);
        CFDataRef expected = SecCertificateCopyData(expectedCertificate);
        matchesBaseline = actual != NULL && expected != NULL && CFEqual(actual, expected);
        [report appendFormat:@"Same certificate as baseline: %@\n",
                             matchesBaseline ? @"yes" : @"NO (different identity)"];
        if (actual != NULL) {
            CFRelease(actual);
        }
        if (expected != NULL) {
            CFRelease(expected);
        }
    }
    if (!matchesBaseline) {
        [report appendString:@"FAIL: different identity; signing comparison skipped.\n"];
        if (privateKey != NULL) {
            CFRelease(privateKey);
        }
        if (certificate != NULL) {
            CFRelease(certificate);
        }
        return;
    }
    SecKeyRef publicKey = CopyDiagnosticCertificatePublicKey(certificate, report);
    AppendSigningProbe(report, privateKey, publicKey, digestInfo, YES);
    if (publicKey != NULL) {
        CFRelease(publicKey);
    }
    if (privateKey != NULL) {
        CFRelease(privateKey);
    }
    if (certificate != NULL) {
        CFRelease(certificate);
    }
}

static SecCertificateRef CopyDiagnosticCertificate(NSString *keychainLabel, NSMutableString *report) {
    NSDictionary *query =
        [NSDictionary dictionaryWithObjectsAndKeys:(id)kSecClassCertificate, (id)kSecClass, keychainLabel,
                                                   (id)kSecAttrLabel, (id)kCFBooleanTrue, (id)kSecReturnRef,
                                                   (id)kSecMatchLimitOne, (id)kSecMatchLimit, nil];
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((CFDictionaryRef)query, &result);
    [report appendFormat:@"Stored certificate query=%ld\n", (long)status];
    if (status == errSecSuccess && result != NULL && CFGetTypeID(result) == SecCertificateGetTypeID()) {
        return (SecCertificateRef)result;
    }
    if (result != NULL) {
        CFRelease(result);
    }
    return NULL;
}

static void AppendLookupComparison(NSMutableString *report, NSString *keychainLabel, NSData *applicationTag,
                                   SecCertificateRef expectedCertificate, NSData *digestInfo) {
    [report appendString:@"\nOriginal identity lookup:\n"];
    NSMutableDictionary *query = [NSMutableDictionary
        dictionaryWithObjectsAndKeys:(id)kSecClassIdentity, (id)kSecClass, keychainLabel, (id)kSecAttrLabel,
                                     (id)kCFBooleanTrue, (id)kSecReturnRef, (id)kSecMatchLimitOne,
                                     (id)kSecMatchLimit, nil];
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((CFDictionaryRef)query, &result);
    [report appendFormat:@"query=%ld\n", (long)status];
    SecCertificateRef baselineCertificate = expectedCertificate;
    if (baselineCertificate != NULL) {
        CFRetain(baselineCertificate);
    }
    if (status == errSecSuccess && result != NULL && CFGetTypeID(result) == SecIdentityGetTypeID()) {
        if (baselineCertificate == NULL) {
            SecIdentityCopyCertificate((SecIdentityRef)result, &baselineCertificate);
        }
        AppendIdentityProbe(report, (SecIdentityRef)result, baselineCertificate, digestInfo);
    }
    if (result != NULL) {
        CFRelease(result);
    }

    if (baselineCertificate != NULL) {
        CFDataRef encoded = SecCertificateCopyData(baselineCertificate);
        if (encoded != NULL) {
            unsigned char hash[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256(CFDataGetBytePtr(encoded), (CC_LONG)CFDataGetLength(encoded), hash);
            [report appendString:@"Baseline certificate SHA-256: "];
            NSUInteger index;
            for (index = 0; index < sizeof(hash); index++) {
                [report appendFormat:@"%02X", hash[index]];
            }
            [report appendString:@"\n"];
            CFRelease(encoded);
        }
    }

    [report appendString:@"\nIdentity lookup restricted to PRIVATE keys:\n"];
    [query setObject:(id)kSecAttrKeyClassPrivate forKey:(id)kSecAttrKeyClass];
    result = NULL;
    status = SecItemCopyMatching((CFDictionaryRef)query, &result);
    [report appendFormat:@"query=%ld\n", (long)status];
    if (status == errSecSuccess && result != NULL && CFGetTypeID(result) == SecIdentityGetTypeID()) {
        AppendIdentityProbe(report, (SecIdentityRef)result, baselineCertificate, digestInfo);
    }
    if (result != NULL) {
        CFRelease(result);
    }

    [report appendString:@"\nDirect PRIVATE key lookup:\n"];
    SecKeyRef certificatePublicKey = CopyDiagnosticCertificatePublicKey(baselineCertificate, report);
    [query setObject:(id)kSecClassKey forKey:(id)kSecClass];
    [query setObject:(id)kSecAttrKeyTypeRSA forKey:(id)kSecAttrKeyType];
    [query setObject:(id)kSecMatchLimitAll forKey:(id)kSecMatchLimit];
    if (applicationTag != nil) {
        [query removeObjectForKey:(id)kSecAttrLabel];
        [query setObject:applicationTag forKey:(id)kSecAttrApplicationTag];
    }
    result = NULL;
    status = SecItemCopyMatching((CFDictionaryRef)query, &result);
    NSString *lookupDescription = applicationTag != nil
                                      ? @"exact diagnostic tag"
                                      : @"existing app label; each key checked against baseline certificate";
    [report appendFormat:@"query=%ld (%@)\n", (long)status, lookupDescription];
    if (status == errSecSuccess && result != NULL && CFGetTypeID(result) == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount((CFArrayRef)result);
        [report appendFormat:@"Matched private keys: %ld\n", (long)count];
        CFIndex index;
        for (index = 0; index < count && index < 16; index++) {
            [report appendFormat:@"Key %ld: ", (long)index + 1];
            AppendSigningProbe(report, (SecKeyRef)CFArrayGetValueAtIndex((CFArrayRef)result, index),
                               certificatePublicKey, digestInfo, YES);
        }
        if (count > 16) {
            [report appendString:@"Remaining keys omitted.\n"];
        }
    }
    if (result != NULL) {
        CFRelease(result);
    }
    if (certificatePublicKey != NULL) {
        CFRelease(certificatePublicKey);
    }
    if (baselineCertificate != NULL) {
        CFRelease(baselineCertificate);
    }
}

static void AppendFreshKeyTest(NSMutableString *report, NSData *digestInfo) {
    NSString *unique = [[NSProcessInfo processInfo] globallyUniqueString];
    NSString *keychainLabel = [@"LocalSend lookup diagnostic " stringByAppendingString:unique];
    NSData *applicationTag = [[@"com.example.localsend.lookup-diagnostic." stringByAppendingString:unique]
        dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *publicAttributes = [NSDictionary
        dictionaryWithObjectsAndKeys:(id)kCFBooleanTrue, (id)kSecAttrIsPermanent, applicationTag,
                                     (id)kSecAttrApplicationTag, keychainLabel, (id)kSecAttrLabel, nil];
    NSDictionary *privateAttributes = [NSDictionary
        dictionaryWithObjectsAndKeys:(id)kCFBooleanTrue, (id)kSecAttrIsPermanent, (id)kCFBooleanTrue,
                                     (id)kSecAttrCanSign, applicationTag, (id)kSecAttrApplicationTag,
                                     keychainLabel, (id)kSecAttrLabel, nil];
    NSDictionary *parameters =
        [NSDictionary dictionaryWithObjectsAndKeys:(id)kSecAttrKeyTypeRSA, (id)kSecAttrKeyType,
                                                   [NSNumber numberWithInt:2048], (id)kSecAttrKeySizeInBits,
                                                   publicAttributes, (id)kSecPublicKeyAttrs,
                                                   privateAttributes, (id)kSecPrivateKeyAttrs, nil];
    SecKeyRef publicKey = NULL;
    SecKeyRef privateKey = NULL;
    SecCertificateRef certificate = NULL;
    CFTypeRef publicData = NULL;
    OSStatus status = SecKeyGeneratePair((CFDictionaryRef)parameters, &publicKey, &privateKey);
    [report appendFormat:@"Generate RSA-2048 pair=%ld\n", (long)status];
    if (status == errSecSuccess && publicKey != NULL && privateKey != NULL) {
        [report appendString:@"Fresh private reference, verify with generated public key:\n"];
        AppendSigningProbe(report, privateKey, publicKey, digestInfo, NO);
        NSDictionary *publicQuery = [NSDictionary
            dictionaryWithObjectsAndKeys:(id)kSecClassKey, (id)kSecClass, applicationTag,
                                         (id)kSecAttrApplicationTag, (id)kSecAttrKeyClassPublic,
                                         (id)kSecAttrKeyClass, (id)kCFBooleanTrue, (id)kSecReturnData, nil];
        status = SecItemCopyMatching((CFDictionaryRef)publicQuery, &publicData);
        [report appendFormat:@"Public key export=%ld\n", (long)status];
        if (status == errSecSuccess && publicData != NULL && CFGetTypeID(publicData) == CFDataGetTypeID()) {
            NSString *errorMessage = nil;
            certificate = LocalSendCreateDeviceCertificate((NSData *)publicData, privateKey, &errorMessage);
            if (certificate == NULL) {
                [report appendFormat:@"Create test certificate: %@\n", errorMessage];
            } else {
                [report appendString:@"Fresh private reference, verify with CERTIFICATE public key:\n"];
                SecKeyRef certificatePublicKey = CopyDiagnosticCertificatePublicKey(certificate, report);
                AppendSigningProbe(report, privateKey, certificatePublicKey, digestInfo, YES);
                if (certificatePublicKey != NULL) {
                    CFRelease(certificatePublicKey);
                }
                NSDictionary *certificateItem = [NSDictionary
                    dictionaryWithObjectsAndKeys:(id)kSecClassCertificate, (id)kSecClass, (id)certificate,
                                                 (id)kSecValueRef, keychainLabel, (id)kSecAttrLabel, nil];
                status = SecItemAdd((CFDictionaryRef)certificateItem, NULL);
                [report appendFormat:@"Store test certificate=%ld\n", (long)status];
            }
        }
        AppendLookupComparison(report, keychainLabel, applicationTag, certificate, digestInfo);
    }
    if (publicData != NULL) {
        CFRelease(publicData);
    }
    if (certificate != NULL) {
        CFRelease(certificate);
    }
    if (publicKey != NULL) {
        CFRelease(publicKey);
    }
    if (privateKey != NULL) {
        CFRelease(privateKey);
    }
    /* Delete only this run's uniquely named test records. */
    NSDictionary *deleteCertificate =
        [NSDictionary dictionaryWithObjectsAndKeys:(id)kSecClassCertificate, (id)kSecClass, keychainLabel,
                                                   (id)kSecAttrLabel, nil];
    NSDictionary *deleteKeys =
        [NSDictionary dictionaryWithObjectsAndKeys:(id)kSecClassKey, (id)kSecClass, applicationTag,
                                                   (id)kSecAttrApplicationTag, nil];
    OSStatus certificateCleanup = SecItemDelete((CFDictionaryRef)deleteCertificate);
    OSStatus keyCleanup = SecItemDelete((CFDictionaryRef)deleteKeys);
    [report appendFormat:@"\nTemporary-record cleanup: certificate=%ld, keys=%ld\n", (long)certificateCleanup,
                         (long)keyCleanup];
}

@implementation LocalSendKeyDiagnostics

+ (NSString *)runKeyLookupDiagnostics {
    @synchronized([LocalSendIdentityStore class]) {
        NSMutableString *report = [NSMutableString
            stringWithFormat:@"LocalSend key lookup test 1\n%@\niOS %@; %@\n\n"
                              "PASS means sign=0 and verify=0 against the certificate public key.\n"
                              "Self-signed trust results are informational; no network trust is changed.\n"
                              "Only public metadata and result codes appear in this report.\n",
                             [NSDate date], [[UIDevice currentDevice] systemVersion],
                             [[UIDevice currentDevice] model]];
        unsigned char challenge[32];
        OSStatus status = SecRandomCopyBytes(kSecRandomDefault, sizeof(challenge), challenge);
        if (status != errSecSuccess) {
            [report appendFormat:@"Random challenge generation failed: %ld\n", (long)status];
            return report;
        }
        NSData *digestInfo = LocalSendSHA256DigestInfo([NSData dataWithBytes:challenge
                                                                      length:sizeof(challenge)]);
        [report appendString:@"\n=== EXISTING APP IDENTITY (v5) ===\n"];
        SecCertificateRef certificate = CopyDiagnosticCertificate(LocalSendIdentityKeychainLabel, report);
        AppendLookupComparison(report, LocalSendIdentityKeychainLabel, nil, certificate, digestInfo);
        if (certificate != NULL) {
            CFRelease(certificate);
        }
        [report appendString:@"\n=== FRESH TEMPORARY IDENTITY ===\n"
                              "Uses the app's key-generation attributes and certificate builder.\n"];
        AppendFreshKeyTest(report, digestInfo);
        [report appendString:
                    @"\n=== NEXT CHECK ===\n"
                     "Copy this report. Fully close and reopen the app, then run Key test again.\n"
                     "The existing v5 identity is preserved so its results can be compared after relaunch.\n"
                     "Transfer identity lookups are restricted to private keys.\n"
                     "A local PASS does not prove that the HTTPS handshake or transfer will succeed.\n"];
        return report;
    }
}

@end
