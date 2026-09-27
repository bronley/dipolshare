#import <Security/Security.h>
/* The current macOS SDK hides this iOS API declaration. The macOS Security
 * framework still exports it; tests call the actual native implementation. */
extern OSStatus SecKeyRawSign(SecKeyRef key, SecPadding padding, const uint8_t *dataToSign,
                              size_t dataToSignLen, uint8_t *sig, size_t *sigLen);
