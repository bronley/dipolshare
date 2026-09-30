#import "LocalSendTLS.h"
#import "LocalSendConnectionActivity.h"
#import <CommonCrypto/CommonDigest.h>
#define OPENSSL_SUPPRESS_DEPRECATED
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>

/* OpenSSL 3.5 LTS retains RSA_METHOD. This bridge deliberately supports only
 * TLS 1.2 PKCS#1 signatures; it never exports the Keychain private key. */
typedef struct {
    SecKeyRef privateKey; /* Retained by the owning LocalSendTLS. */
    OSStatus signingStatus;
    LocalSendConnectionActivity *activity;
} LocalSendKeychainSigningContext;

static RSA_METHOD *LocalSendKeychainRSAMethod;
static int LocalSendKeychainContextIndex = -1;
static BOOL LocalSendTLSLibraryReady;
static NSString *const LocalSendTLSInitializationErrorKey = @"LocalSendTLS.initializationError";
static pthread_once_t LocalSendTLSInitializationOnce = PTHREAD_ONCE_INIT;

static int LocalSendSignWithKeychainPrivateKey(int digestLength, const unsigned char *digestBytes,
                                               unsigned char *signatureBytes, RSA *rsa, int padding) {
    LocalSendKeychainSigningContext *signingContext = RSA_get_ex_data(rsa, LocalSendKeychainContextIndex);
    if (signingContext == NULL || signingContext->privateKey == NULL || digestLength <= 0 ||
        digestBytes == NULL || signatureBytes == NULL || padding != RSA_PKCS1_PADDING ||
        [signingContext->activity isCancelled]) {
        return -1;
    }
    size_t signatureCapacity = SecKeyGetBlockSize(signingContext->privateKey);
    size_t signatureLength = signatureCapacity;
    if (signatureCapacity == 0 || signatureCapacity > INT_MAX || signatureCapacity != (size_t)RSA_size(rsa)) {
        return -1;
    }
    NSString *previousStage = [signingContext->activity stage];
    [signingContext->activity setStage:@"Keychain RSA signing"];
    signingContext->signingStatus = SecKeyRawSign(signingContext->privateKey, kSecPaddingPKCS1, digestBytes,
                                                  (size_t)digestLength, signatureBytes, &signatureLength);
    if ([signingContext->activity isCancelled]) return -1;
    if (signingContext->signingStatus != errSecSuccess || signatureLength != signatureCapacity) {
        ERR_raise(ERR_LIB_USER, 1);
        return -1;
    }
    if (previousStage != nil) [signingContext->activity setStage:previousStage];
    return (int)signatureLength;
}

static int LocalSendRejectPrivateKeyDecryption(int digestLength, const unsigned char *digestBytes,
                                               unsigned char *signatureBytes, RSA *rsa, int padding) {
    (void)digestLength;
    (void)digestBytes;
    (void)signatureBytes;
    (void)rsa;
    (void)padding;
    return -1; /* Only forward-secret ECDHE suites are enabled. */
}

static void LocalSendInitializeTLSLibrary(void) {
    /* No external OpenSSL configuration, engines, or provider modules. */
    if (OPENSSL_init_ssl(OPENSSL_INIT_NO_LOAD_CONFIG, NULL) != 1) {
        return;
    }
    LocalSendKeychainContextIndex = RSA_get_ex_new_index(0, NULL, NULL, NULL, NULL);
    if (LocalSendKeychainContextIndex < 0) {
        return;
    }
    LocalSendKeychainRSAMethod = RSA_meth_dup(RSA_PKCS1_OpenSSL());
    if (LocalSendKeychainRSAMethod == NULL) {
        return;
    }
    if (RSA_meth_set_priv_enc(LocalSendKeychainRSAMethod, LocalSendSignWithKeychainPrivateKey) != 1 ||
        RSA_meth_set_priv_dec(LocalSendKeychainRSAMethod, LocalSendRejectPrivateKeyDecryption) != 1) {
        return;
    }
    LocalSendTLSLibraryReady = YES;
}

/* LocalSend authenticates the exact certificate fingerprint in the app.
 * Permit only a self-signed leaf; all other X.509 errors remain errors. */
static int LocalSendVerifyPeerCertificate(int verified, X509_STORE_CTX *store) {
    if (verified) {
        return 1;
    }
    return X509_STORE_CTX_get_error_depth(store) == 0 &&
           X509_STORE_CTX_get_error(store) == X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT;
}

static X509 *LocalSendCopyIdentityCertificate(SecIdentityRef identity, SecKeyRef *privateKey) {
    SecCertificateRef certificate = NULL;
    CFDataRef der = NULL;
    X509 *x509 = NULL;
    if (SecIdentityCopyCertificate(identity, &certificate) != errSecSuccess || certificate == NULL ||
        SecIdentityCopyPrivateKey(identity, privateKey) != errSecSuccess || *privateKey == NULL) {
        goto failed;
    }
    der = SecCertificateCopyData(certificate);
    if (der == NULL || CFDataGetLength(der) <= 0 || CFDataGetLength(der) > 65536) {
        goto failed;
    }
    const unsigned char *cursor = CFDataGetBytePtr(der);
    x509 = d2i_X509(NULL, &cursor, (long)CFDataGetLength(der));
    if (x509 == NULL || cursor != CFDataGetBytePtr(der) + CFDataGetLength(der)) {
        goto failed;
    }
    CFRelease(der);
    CFRelease(certificate);
    return x509;

failed:
    X509_free(x509);
    if (der != NULL) {
        CFRelease(der);
    }
    if (certificate != NULL) {
        CFRelease(certificate);
    }
    return NULL;
}

static BOOL LocalSendPrivateKeyMatchesCertificate(RSA *signingRSA, RSA *publicRSA,
                                                  LocalSendConnectionActivity *activity) {
    /* Matching public parameters alone does not prove that the opaque Keychain
     * reference can sign for this certificate. Verify a real native signature. */
    static const char challenge[] = "LocalSend OpenSSL Keychain identity check";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(challenge, sizeof(challenge) - 1, digest);
    unsigned int signatureLength = 0;
    unsigned char *signature = malloc((size_t)RSA_size(signingRSA));
    if (signature == NULL) {
        return NO;
    }
    BOOL keyMatches = RSA_sign(NID_sha256, digest, sizeof(digest), signature, &signatureLength, signingRSA) == 1;
    if (keyMatches) {
        [activity setStage:@"Verifying identity signature"];
        keyMatches = RSA_verify(NID_sha256, digest, sizeof(digest), signature, signatureLength, publicRSA) == 1;
    }
    OPENSSL_clear_free(signature, (size_t)RSA_size(signingRSA));
    return keyMatches;
}

static EVP_PKEY *LocalSendCreateKeychainSigningKey(X509 *x509, SecKeyRef privateKey, void **keyContext,
                                                 LocalSendConnectionActivity *activity) {
    EVP_PKEY *publicKey = NULL, *signingKey = NULL;
    RSA *publicRSA = NULL, *signingRSA = NULL;
    BIGNUM *modulusCopy = NULL, *exponentCopy = NULL;
    publicKey = X509_get_pubkey(x509);
    if (publicKey == NULL || (publicRSA = EVP_PKEY_get1_RSA(publicKey)) == NULL) {
        goto failed;
    }
    const BIGNUM *modulus = NULL, *exponent = NULL;
    RSA_get0_key(publicRSA, &modulus, &exponent, NULL);
    if (modulus == NULL || exponent == NULL || BN_num_bits(modulus) < 2048) {
        goto failed;
    }
    modulusCopy = BN_dup(modulus);
    exponentCopy = BN_dup(exponent);
    signingRSA = RSA_new();
    if (modulusCopy == NULL || exponentCopy == NULL || signingRSA == NULL ||
        RSA_set0_key(signingRSA, modulusCopy, exponentCopy, NULL) != 1) {
        goto failed;
    }
    modulusCopy = NULL;
    exponentCopy = NULL; /* Owned by signingRSA. */
    *keyContext = calloc(1, sizeof(LocalSendKeychainSigningContext));
    if (*keyContext == NULL) {
        goto failed;
    }
    ((LocalSendKeychainSigningContext *)*keyContext)->privateKey = privateKey;
    ((LocalSendKeychainSigningContext *)*keyContext)->activity = activity;
    if (RSA_set_method(signingRSA, LocalSendKeychainRSAMethod) != 1 ||
        RSA_set_ex_data(signingRSA, LocalSendKeychainContextIndex, *keyContext) != 1) {
        goto failed;
    }
    if (!LocalSendPrivateKeyMatchesCertificate(signingRSA, publicRSA, activity)) {
        goto failed;
    }
    signingKey = EVP_PKEY_new();
    if (signingKey == NULL || EVP_PKEY_assign_RSA(signingKey, signingRSA) != 1) {
        goto failed;
    }
    signingRSA = NULL; /* Owned by signingKey. */

    RSA_free(publicRSA);
    EVP_PKEY_free(publicKey);
    return signingKey;

failed:
    BN_free(modulusCopy);
    BN_free(exponentCopy);
    EVP_PKEY_free(signingKey);
    RSA_free(signingRSA);
    RSA_free(publicRSA);
    EVP_PKEY_free(publicKey);
    return NULL;
}

static BOOL LocalSendConfigureTLSContext(SSL_CTX *tlsContext, BOOL server) {
    if (tlsContext == NULL || SSL_CTX_set_min_proto_version(tlsContext, TLS1_2_VERSION) != 1 ||
        SSL_CTX_set_max_proto_version(tlsContext, TLS1_2_VERSION) != 1) {
        return NO;
    }
    uint64_t options = SSL_OP_NO_TICKET | SSL_OP_NO_COMPRESSION | SSL_OP_NO_RENEGOTIATION;
    if (server) {
        options |= SSL_OP_CIPHER_SERVER_PREFERENCE;
    }
    if ((SSL_CTX_set_options(tlsContext, options) & options) != options ||
        SSL_CTX_set_cipher_list(tlsContext,
                                "ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-CHACHA20-POLY1305:"
                                "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:"
                                "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384") != 1 ||
        SSL_CTX_set1_sigalgs_list(
            tlsContext, "RSA+SHA256:RSA+SHA384:RSA+SHA512:ECDSA+SHA256:ECDSA+SHA384:ECDSA+SHA512") != 1) {
        return NO;
    }
    SSL_CTX_set_security_level(tlsContext, 2);
    SSL_CTX_set_session_cache_mode(tlsContext, SSL_SESS_CACHE_OFF);
    SSL_CTX_set_verify_depth(tlsContext, 4);
    SSL_CTX_set_verify(tlsContext, SSL_VERIFY_PEER | (server ? SSL_VERIFY_FAIL_IF_NO_PEER_CERT : 0),
                       LocalSendVerifyPeerCertificate);
    return YES;
}

@interface LocalSendTLS ()
- (void)setFailureMessage:(NSString *)stage;
- (LocalSendTLSOperationResult)handleOperationResult:(int)result failureMessage:(NSString *)stage;
@end

@implementation LocalSendTLS

+ (NSString *)libraryVersion {
    return [NSString stringWithUTF8String:OpenSSL_version(OPENSSL_VERSION)];
}

+ (NSString *)lastInitializationError {
    return [[[NSThread currentThread] threadDictionary] objectForKey:LocalSendTLSInitializationErrorKey];
}

- (id)initWithIdentity:(SecIdentityRef)identity socket:(int)socketDescriptor server:(BOOL)server {
    return [self initWithIdentity:identity socket:socketDescriptor server:server activity:nil];
}

- (id)initWithIdentity:(SecIdentityRef)identity socket:(int)socketDescriptor server:(BOOL)server
              activity:(LocalSendConnectionActivity *)activity {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _isServer = server;
    _wantsRead = server;
    _activity = [activity retain];
    [[[NSThread currentThread] threadDictionary] removeObjectForKey:LocalSendTLSInitializationErrorKey];
    X509 *certificate = NULL;
    EVP_PKEY *signingKey = NULL;
    BIO *socketBIO = NULL;
    [_activity setStage:@"Initializing OpenSSL"];
    pthread_once(&LocalSendTLSInitializationOnce, LocalSendInitializeTLSLibrary);
    int flags = socketDescriptor >= 0 ? fcntl(socketDescriptor, F_GETFL, 0) : -1;
    if (!LocalSendTLSLibraryReady || identity == NULL || flags < 0 || !(flags & O_NONBLOCK) ||
        [_activity isCancelled]) {
        goto failed;
    }
    ERR_clear_error();

    unsigned char randomCheck[16];
    [_activity setStage:@"Seeding TLS random generator"];
    if (RAND_bytes(randomCheck, sizeof(randomCheck)) != 1) {
        goto failed;
    }
    OPENSSL_cleanse(randomCheck, sizeof(randomCheck));

    [_activity setStage:@"Reading Keychain identity"];
    certificate = LocalSendCopyIdentityCertificate(identity, &_privateKey);
    if (certificate == NULL || [_activity isCancelled]) {
        goto failed;
    }
    [_activity setStage:@"Building Keychain RSA bridge"];
    signingKey = LocalSendCreateKeychainSigningKey(certificate, _privateKey, &_keyContext, _activity);
    if (signingKey == NULL || [_activity isCancelled]) {
        goto failed;
    }

    [_activity setStage:@"Creating OpenSSL context"];
    SSL_CTX *tlsContext = SSL_CTX_new(server ? TLS_server_method() : TLS_client_method());
    _tlsContext = tlsContext;
    if (!LocalSendConfigureTLSContext(tlsContext, server)) {
        goto failed;
    }
    [_activity setStage:@"Installing TLS identity"];
    if (SSL_CTX_use_certificate(tlsContext, certificate) != 1 ||
        SSL_CTX_use_PrivateKey(tlsContext, signingKey) != 1 || SSL_CTX_check_private_key(tlsContext) != 1) {
        goto failed;
    }
    [_activity setStage:@"Creating TLS session"];
    _tlsSession = SSL_new(tlsContext);
    if (_tlsSession == NULL) {
        goto failed;
    }
    socketBIO = BIO_new_socket(socketDescriptor, BIO_NOCLOSE);
    if (socketBIO == NULL) {
        goto failed;
    }
    SSL_set_bio(_tlsSession, socketBIO, socketBIO);
    socketBIO = NULL;
    EVP_PKEY_free(signingKey);
    X509_free(certificate);
    return self;

failed:
    [self setFailureMessage:@"TLS setup failed"];
    [[[NSThread currentThread] threadDictionary] setObject:_errorMessage
                                                    forKey:LocalSendTLSInitializationErrorKey];
    NSLog(@"LocalSend %@", _errorMessage);
    BIO_free(socketBIO);
    EVP_PKEY_free(signingKey);
    X509_free(certificate);
    [self release];
    return nil;
}

- (void)setFailureMessage:(NSString *)stage {
    NSString *detail = nil;
    if (_keyContext != NULL &&
        ((LocalSendKeychainSigningContext *)_keyContext)->signingStatus != errSecSuccess) {
        detail =
            [NSString stringWithFormat:@"Keychain signing returned OSStatus %ld",
                                       (long)((LocalSendKeychainSigningContext *)_keyContext)->signingStatus];
    } else {
        unsigned long error = ERR_peek_last_error();
        if (error != 0) {
            char text[256];
            ERR_error_string_n(error, text, sizeof(text));
            detail = [NSString stringWithUTF8String:text];
        }
    }
    [_errorMessage release];
    _errorMessage = [(detail != nil ? [NSString stringWithFormat:@"%@: %@.", stage, detail]
                                    : [stage stringByAppendingString:@"."]) copy];
}

- (LocalSendTLSOperationResult)handleOperationResult:(int)result failureMessage:(NSString *)stage {
    /* Called immediately after the SSL operation, on the same thread. */
    int error = SSL_get_error(_tlsSession, result);
    if (error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE) {
        _wantsRead = error == SSL_ERROR_WANT_READ;
        return LocalSendTLSOperationWouldBlock;
    }
    if (error == SSL_ERROR_ZERO_RETURN) {
        return LocalSendTLSConnectionClosed;
    }
    [self setFailureMessage:stage];
    return LocalSendTLSOperationFailed;
}

- (LocalSendTLSOperationResult)handshake {
    if (_tlsSession == NULL) {
        return LocalSendTLSOperationFailed;
    }
    if (_handshakeComplete) {
        return LocalSendTLSOperationCompleted;
    }
    [_activity setStage:_isServer ? @"TLS handshake (accept)" : @"TLS handshake (connect)"];
    ERR_clear_error();
    int result = _isServer ? SSL_accept(_tlsSession) : SSL_connect(_tlsSession);
    if (result <= 0) {
        return [self handleOperationResult:result failureMessage:@"TLS handshake failed"];
    }
    if (SSL_version(_tlsSession) != TLS1_2_VERSION) {
        return LocalSendTLSOperationFailed;
    }
    [_activity setStage:@"Verifying peer certificate"];
    X509 *leaf = SSL_get1_peer_certificate(_tlsSession);
    if (leaf == NULL) {
        [self setFailureMessage:@"Peer certificate is missing"];
        return LocalSendTLSOperationFailed;
    }
    EVP_PKEY *key = X509_get_pubkey(leaf);
    BOOL valid = key != NULL && X509_verify(leaf, key) == 1 &&
                 X509_cmp_current_time(X509_get0_notBefore(leaf)) < 0 &&
                 X509_cmp_current_time(X509_get0_notAfter(leaf)) > 0;
    EVP_PKEY_free(key);
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int length = 0;
    if (valid) {
        valid = X509_digest(leaf, EVP_sha256(), digest, &length) == 1 && length == 32;
    }
    X509_free(leaf);
    if (!valid) {
        [self setFailureMessage:@"Peer self-signed certificate is invalid or expired"];
        return LocalSendTLSOperationFailed;
    }
    NSMutableString *fingerprint = [[NSMutableString alloc] initWithCapacity:64];
    NSUInteger index;
    for (index = 0; index < length; index++) {
        [fingerprint appendFormat:@"%02X", digest[index]];
    }
    _peerFingerprint = fingerprint;
    _handshakeComplete = YES;
    return LocalSendTLSOperationCompleted;
}

- (LocalSendTLSOperationResult)read:(void *)buffer length:(size_t)length processed:(size_t *)processed {
    if (processed != NULL) {
        *processed = 0;
    }
    if (!_handshakeComplete || _tlsSession == NULL || buffer == NULL || processed == NULL) {
        return LocalSendTLSOperationFailed;
    }
    if (length == 0) {
        return LocalSendTLSOperationCompleted;
    }
    ERR_clear_error();
    int result = SSL_read(_tlsSession, buffer, (int)MIN(length, (size_t)INT_MAX));
    if (result > 0) {
        *processed = (size_t)result;
        return LocalSendTLSOperationCompleted;
    }
    return [self handleOperationResult:result failureMessage:@"TLS read failed"];
}

- (LocalSendTLSOperationResult)write:(const void *)buffer
                              length:(size_t)length
                           processed:(size_t *)processed {
    if (processed != NULL) {
        *processed = 0;
    }
    if (!_handshakeComplete || _tlsSession == NULL || buffer == NULL || processed == NULL) {
        return LocalSendTLSOperationFailed;
    }
    if (length == 0) {
        return LocalSendTLSOperationCompleted;
    }
    ERR_clear_error();
    int result = SSL_write(_tlsSession, buffer, (int)MIN(length, (size_t)INT_MAX));
    if (result > 0) {
        *processed = (size_t)result;
        return LocalSendTLSOperationCompleted;
    }
    return [self handleOperationResult:result failureMessage:@"TLS write failed"];
}

- (BOOL)wantsRead {
    return _wantsRead;
}
- (NSString *)peerFingerprint {
    return _peerFingerprint;
}
- (NSString *)errorMessage {
    return _errorMessage;
}
- (void)close {
    if (_tlsSession != NULL) {
        if (_handshakeComplete) {
            ERR_clear_error();
            SSL_shutdown(_tlsSession);
        }
        SSL_free(_tlsSession);
        _tlsSession = NULL;
    }
    SSL_CTX_free(_tlsContext);
    _tlsContext = NULL;
    if (_privateKey != NULL) {
        CFRelease(_privateKey);
        _privateKey = NULL;
    }
    if (_keyContext != NULL) {
        free(_keyContext);
        _keyContext = NULL;
    }
    _handshakeComplete = NO;
}
- (void)dealloc {
    [self close];
    [_peerFingerprint release];
    [_errorMessage release];
    [_activity release];
    [super dealloc];
}
@end
