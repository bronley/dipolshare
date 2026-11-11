#import "Discovery+Private.h"
#import "IdentityStore.h"
#import "Receiver.h"

@interface IdentityLoadResult : NSObject {
@public
    SecIdentityRef identity;
    NSString *fingerprint;
    NSString *error;
}
@end
@implementation IdentityLoadResult
- (void)dealloc {
    if (identity != NULL) {
        CFRelease(identity);
    }
    [fingerprint release];
    [error release];
    [super dealloc];
}
@end

@implementation Discovery (Identity)

- (void)loadIdentityInBackground {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    IdentityLoadResult *result = [[IdentityLoadResult alloc] init];
    NSString *fingerprint = nil;
    NSString *error = nil;
    result->identity = [IdentityStore copyIdentityWithFingerprint:&fingerprint
                                                                    error:&error
                                                               willCreate:^{
                                                                   [self performSelectorOnMainThread:@selector(firstSetupStarted:)
                                                                                          withObject:nil
                                                                                       waitUntilDone:NO];
                                                               }];
    result->fingerprint = [fingerprint copy];
    result->error = [error copy];
    [self performSelectorOnMainThread:@selector(identityLoaded:) withObject:result waitUntilDone:NO];
    [result release];
    [pool release];
}

- (void)firstSetupStarted:(id)unused {
    _firstSetupInProgress = YES;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:DiscoverySetupDidChangeNotification object:self userInfo:nil];
}

- (void)identityLoaded:(IdentityLoadResult *)result {
    _identityLoading = NO;
    if (_firstSetupInProgress) {
        _firstSetupInProgress = NO;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:DiscoverySetupDidChangeNotification object:self userInfo:nil];
    }
    if (result->identity == NULL || result->fingerprint == nil) {
        [_identitySetupError release];
        _identitySetupError = [(result->error != nil ? result->error : @"Could not create the device identity.") copy];
        NSLog(@"LocalSend discovery identity: %@", result->error);
        [[NSNotificationCenter defaultCenter]
            postNotificationName:DiscoverySetupDidChangeNotification object:self userInfo:nil];
        if (_running) {
            [self stop];
        }
        return;
    }
    [_identitySetupError release];
    _identitySetupError = nil;
    if (_identity == NULL) {
        _identity = (SecIdentityRef)CFRetain(result->identity);
    }
    [_identityFingerprint release];
    _identityFingerprint = [result->fingerprint copy];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:DiscoverySetupDidChangeNotification object:self userInfo:nil];
    if (_running) {
        [self finishStartingWithFingerprint:_identityFingerprint];
    }
}

- (BOOL)isFirstSetupInProgress {
    return _firstSetupInProgress;
}

- (BOOL)isRegeneratingIdentity {
    return _identityRegenerating;
}

- (CertificateDateStatus)certificateDateStatus {
    return [IdentityStore certificateDateStatusForIdentity:_identity];
}

- (NSString *)identityFingerprint {
    return _identityFingerprint;
}

- (NSString *)identitySetupError {
    return _identitySetupError;
}

- (BOOL)regenerateIdentity {
    if (_identityLoading || _identityRegenerating) {
        return NO;
    }
    _identityRegenerating = YES;
    [NSThread detachNewThreadSelector:@selector(regenerateIdentityInBackground)
                             toTarget:self
                           withObject:nil];
    return YES;
}

- (void)regenerateIdentityInBackground {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    IdentityLoadResult *result = [[IdentityLoadResult alloc] init];
    NSString *fingerprint = nil;
    NSString *error = nil;
    result->identity = [IdentityStore regenerateIdentityWithFingerprint:&fingerprint error:&error];
    result->fingerprint = [fingerprint copy];
    result->error = [error copy];
    [self performSelectorOnMainThread:@selector(identityRegenerated:) withObject:result waitUntilDone:NO];
    [result release];
    [pool release];
}

- (void)identityRegenerated:(IdentityLoadResult *)result {
    _identityRegenerating = NO;
    BOOL succeeded = result->identity != NULL && result->fingerprint != nil;
    if (succeeded) {
        [_identitySetupError release];
        _identitySetupError = nil;
        BOOL shouldRestart = _running;
        [self stop];
        if (_identity != NULL) {
            CFRelease(_identity);
        }
        _identity = (SecIdentityRef)CFRetain(result->identity);
        [_identityFingerprint release];
        _identityFingerprint = [result->fingerprint copy];
        if (shouldRestart) {
            [self start];
        }
    }
    NSDictionary *details = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:succeeded], @"success",
        result->error != nil ? result->error : @"Could not create the new identity.", @"error", nil];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:DiscoveryIdentityDidRegenerateNotification
                      object:self
                    userInfo:details];
}
@end
