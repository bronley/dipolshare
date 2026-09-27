#import "LocalSendCertificateBuilder.h"
#import <CommonCrypto/CommonDigest.h>

static NSData *EncodeDERValue(unsigned char tag, NSData *contents) {
    NSMutableData *encoded = [NSMutableData dataWithBytes:&tag length:1];
    NSUInteger contentsLength = [contents length];
    if (contentsLength < 128) {
        unsigned char shortLength = (unsigned char)contentsLength;
        [encoded appendBytes:&shortLength length:1];
    } else {
        unsigned char lengthBytes[sizeof(NSUInteger)];
        NSUInteger lengthByteCount = 0;
        while (contentsLength > 0) {
            lengthBytes[lengthByteCount++] = (unsigned char)(contentsLength & 255);
            contentsLength >>= 8;
        }
        unsigned char lengthPrefix = 0x80 | (unsigned char)lengthByteCount;
        [encoded appendBytes:&lengthPrefix length:1];
        while (lengthByteCount > 0) {
            lengthByteCount--;
            [encoded appendBytes:&lengthBytes[lengthByteCount] length:1];
        }
    }
    [encoded appendData:contents];
    return encoded;
}

static NSData *EncodeDERSequence(NSArray *values) {
    NSMutableData *contents = [NSMutableData data];
    for (NSData *value in values) {
        [contents appendData:value];
    }
    return EncodeDERValue(0x30, contents);
}

static NSData *EncodeDERPositiveInteger(NSData *value) {
    NSMutableData *contents = [NSMutableData dataWithData:value];
    if ([contents length] == 0 || (((const unsigned char *)[contents bytes])[0] & 0x80)) {
        unsigned char zero = 0;
        [contents replaceBytesInRange:NSMakeRange(0, 0) withBytes:&zero length:1];
    }
    return EncodeDERValue(2, contents);
}

static NSData *EncodeDERObjectIdentifier(const unsigned char *bytes, NSUInteger length) {
    return EncodeDERValue(6, [NSData dataWithBytes:bytes length:length]);
}

static NSData *EncodeDERNull(void) {
    return EncodeDERValue(5, [NSData data]);
}

static NSData *EncodeDERUTF8String(NSString *value) {
    return EncodeDERValue(12, [value dataUsingEncoding:NSUTF8StringEncoding]);
}

static NSData *EncodeDERUTCTime(NSString *value) {
    return EncodeDERValue(23, [value dataUsingEncoding:NSASCIIStringEncoding]);
}

static NSData *EncodeDERBitString(NSData *value) {
    unsigned char unusedBitCount = 0;
    NSMutableData *contents = [NSMutableData dataWithBytes:&unusedBitCount length:1];
    [contents appendData:value];
    return EncodeDERValue(3, contents);
}

static NSData *EncodeSHA256WithRSAAlgorithm(void) {
    static const unsigned char identifier[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b};
    return EncodeDERSequence([NSArray
        arrayWithObjects:EncodeDERObjectIdentifier(identifier, sizeof(identifier)), EncodeDERNull(), nil]);
}

static NSData *EncodeSHA256Algorithm(void) {
    static const unsigned char identifier[] = {0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01};
    return EncodeDERSequence([NSArray
        arrayWithObjects:EncodeDERObjectIdentifier(identifier, sizeof(identifier)), EncodeDERNull(), nil]);
}

static NSData *EncodeRSAAlgorithm(void) {
    static const unsigned char identifier[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01};
    return EncodeDERSequence([NSArray
        arrayWithObjects:EncodeDERObjectIdentifier(identifier, sizeof(identifier)), EncodeDERNull(), nil]);
}

static NSData *EncodeCertificateCommonName(void) {
    static const unsigned char identifier[] = {0x55, 0x04, 0x03};
    NSData *attribute =
        EncodeDERSequence([NSArray arrayWithObjects:EncodeDERObjectIdentifier(identifier, sizeof(identifier)),
                                                    EncodeDERUTF8String(@"LocalSend User"), nil]);
    return EncodeDERSequence([NSArray arrayWithObject:EncodeDERValue(0x31, attribute)]);
}

static NSData *EncodeDERTrue(void) {
    unsigned char value = 0xff;
    return EncodeDERValue(1, [NSData dataWithBytes:&value length:1]);
}

static NSData *EncodeDEROctetString(NSData *value) {
    return EncodeDERValue(4, value);
}

static NSData *EncodeCertificateExtension(const unsigned char *identifier, NSUInteger length, BOOL critical,
                                          NSData *value) {
    if (critical) {
        return EncodeDERSequence([NSArray arrayWithObjects:EncodeDERObjectIdentifier(identifier, length),
                                                           EncodeDERTrue(), EncodeDEROctetString(value),
                                                           nil]);
    }
    return EncodeDERSequence([NSArray
        arrayWithObjects:EncodeDERObjectIdentifier(identifier, length), EncodeDEROctetString(value), nil]);
}

NSString *LocalSendSecurityErrorDescription(OSStatus status) {
    return [NSString stringWithFormat:@"Keychain/Security OSStatus %ld", (long)status];
}

NSData *LocalSendSHA256DigestInfo(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256([data bytes], (CC_LONG)[data length], digest);
    return EncodeDERSequence([NSArray
        arrayWithObjects:EncodeSHA256Algorithm(),
                         EncodeDEROctetString([NSData dataWithBytes:digest length:sizeof(digest)]), nil]);
}

NSString *LocalSendCertificateFingerprint(SecCertificateRef certificate) {
    if (certificate == NULL) {
        return nil;
    }
    CFDataRef certificateData = SecCertificateCopyData(certificate);
    if (certificateData == NULL) {
        return nil;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(CFDataGetBytePtr(certificateData), (CC_LONG)CFDataGetLength(certificateData), digest);
    CFRelease(certificateData);

    NSMutableString *fingerprint = [NSMutableString stringWithCapacity:64];
    NSUInteger index;
    for (index = 0; index < sizeof(digest); index++) {
        [fingerprint appendFormat:@"%02X", digest[index]];
    }
    return fingerprint;
}

SecCertificateRef LocalSendCreateDeviceCertificate(NSData *publicKeyData, SecKeyRef privateKey,
                                                   NSString **errorMessage) {
    OSStatus status;
    unsigned char serialBytes[16];
    status = SecRandomCopyBytes(kSecRandomDefault, sizeof(serialBytes), serialBytes);
    if (status != errSecSuccess) {
        if (errorMessage != NULL) {
            *errorMessage =
                [NSString stringWithFormat:@"Could not generate the certificate serial number (%@).",
                                           LocalSendSecurityErrorDescription(status)];
        }
        return NULL;
    }
    serialBytes[0] &= 0x7f;
    serialBytes[0] |= 0x01;
    unsigned char versionValue = 2;

    NSDateFormatter *dateFormatter = [[[NSDateFormatter alloc] init] autorelease];
    [dateFormatter setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
    [dateFormatter setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    [dateFormatter setDateFormat:@"yyMMddHHmmss'Z'"];
    NSString *notBefore = [dateFormatter stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-86400.0]];
    NSString *notAfter = [dateFormatter stringFromDate:[NSDate dateWithTimeIntervalSinceNow:315360000.0]];

    NSData *subjectPublicKeyInfo = EncodeDERSequence(
        [NSArray arrayWithObjects:EncodeRSAAlgorithm(), EncodeDERBitString(publicKeyData), nil]);

    static const unsigned char basicConstraintsOID[] = {0x55, 0x1d, 0x13};
    static const unsigned char keyUsageOID[] = {0x55, 0x1d, 0x0f};
    static const unsigned char extendedKeyUsageOID[] = {0x55, 0x1d, 0x25};
    static const unsigned char clientAuthOID[] = {0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02};
    static const unsigned char serverAuthOID[] = {0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01};

    NSData *basicConstraints = EncodeCertificateExtension(basicConstraintsOID, sizeof(basicConstraintsOID),
                                                          YES, EncodeDERSequence([NSArray array]));
    unsigned char keyUsageBytes[] = {5, 0xa0};
    NSData *keyUsageValue = EncodeDERValue(3, [NSData dataWithBytes:keyUsageBytes
                                                             length:sizeof(keyUsageBytes)]);
    NSData *keyUsage = EncodeCertificateExtension(keyUsageOID, sizeof(keyUsageOID), YES, keyUsageValue);
    NSData *extendedKeyUsageValue = EncodeDERSequence(
        [NSArray arrayWithObjects:EncodeDERObjectIdentifier(clientAuthOID, sizeof(clientAuthOID)),
                                  EncodeDERObjectIdentifier(serverAuthOID, sizeof(serverAuthOID)), nil]);
    NSData *extendedKeyUsage = EncodeCertificateExtension(extendedKeyUsageOID, sizeof(extendedKeyUsageOID),
                                                          NO, extendedKeyUsageValue);
    NSData *extensions = EncodeDERValue(
        0xa3,
        EncodeDERSequence([NSArray arrayWithObjects:basicConstraints, keyUsage, extendedKeyUsage, nil]));

    NSData *validity = EncodeDERSequence(
        [NSArray arrayWithObjects:EncodeDERUTCTime(notBefore), EncodeDERUTCTime(notAfter), nil]);
    NSData *tbsCertificate = EncodeDERSequence([NSArray
        arrayWithObjects:EncodeDERValue(0xa0, EncodeDERPositiveInteger([NSData dataWithBytes:&versionValue
                                                                                      length:1])),
                         EncodeDERPositiveInteger([NSData dataWithBytes:serialBytes
                                                                 length:sizeof(serialBytes)]),
                         EncodeSHA256WithRSAAlgorithm(), EncodeCertificateCommonName(), validity,
                         EncodeCertificateCommonName(), subjectPublicKeyInfo, extensions, nil]);

    NSData *digestInfo = LocalSendSHA256DigestInfo(tbsCertificate);
    NSMutableData *signature = [NSMutableData dataWithLength:SecKeyGetBlockSize(privateKey)];
    size_t signatureLength = [signature length];
    status = SecKeyRawSign(privateKey, kSecPaddingPKCS1, [digestInfo bytes], [digestInfo length],
                           [signature mutableBytes], &signatureLength);
    if (status != errSecSuccess) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"Could not sign the client certificate (%@).",
                                                       LocalSendSecurityErrorDescription(status)];
        }
        return NULL;
    }
    [signature setLength:signatureLength];

    NSData *certificateData = EncodeDERSequence([NSArray
        arrayWithObjects:tbsCertificate, EncodeSHA256WithRSAAlgorithm(), EncodeDERBitString(signature), nil]);
    SecCertificateRef certificate =
        SecCertificateCreateWithData(kCFAllocatorDefault, (CFDataRef)certificateData);
    if (certificate == NULL) {
        if (errorMessage != NULL) {
            *errorMessage = @"The generated X.509 client certificate could not be parsed.";
        }
        return NULL;
    }

    return certificate;
}
