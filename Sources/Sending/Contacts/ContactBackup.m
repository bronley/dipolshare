#import "ContactBackup.h"
#import "VCardWriter.h"
#import <AddressBook/AddressBook.h>
#import <dlfcn.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>

// Look up newer APIs at runtime: the app builds against SDK 5 and runs on iOS 4.
typedef ABAddressBookRef (*CreateBookFunction)(CFDictionaryRef, CFErrorRef *);
typedef void (*RequestAccessFunction)(ABAddressBookRef, void (^)(bool, CFErrorRef));
typedef CFDataRef (*CreateVCardFunction)(CFArrayRef);

static NSString *DateString(NSDate *date, NSTimeZone *timeZone) {
    NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
    formatter.locale = [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
    formatter.calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar] autorelease];
    formatter.timeZone = timeZone;
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:date];
}

static void CopyProperty(NSMutableDictionary *contact, ABRecordRef person, ABPropertyID property, NSString *key) {
    id value = [(id)ABRecordCopyValue(person, property) autorelease];
    if (value != nil) [contact setObject:value forKey:key];
}

static void CopyMultiProperty(NSMutableDictionary *contact, ABRecordRef person,
                              ABPropertyID property, NSString *key) {
    ABMultiValueRef values = ABRecordCopyValue(person, property);
    if (values == NULL) return;
    NSMutableArray *entries = [NSMutableArray array];
    for (CFIndex i = 0; i < ABMultiValueGetCount(values); i++) {
        id value = [(id)ABMultiValueCopyValueAtIndex(values, i) autorelease];
        NSString *label = [(NSString *)ABMultiValueCopyLabelAtIndex(values, i) autorelease];
        if ([value isKindOfClass:[NSDate class]]) value = DateString(value, [NSTimeZone timeZoneForSecondsFromGMT:0]);
        if (value != nil) [entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            value, @"value", label ?: @"", @"label", nil]];
    }
    [contact setObject:entries forKey:key];
    CFRelease(values);
}

static NSData *LegacyVCard(ABRecordRef person) {
    NSMutableDictionary *contact = [NSMutableDictionary dictionary];
    NSString *name = [(NSString *)ABRecordCopyCompositeName(person) autorelease];
    if (name != nil) [contact setObject:name forKey:@"name"];
    ABPropertyID properties[] = {kABPersonFirstNameProperty, kABPersonLastNameProperty,
        kABPersonMiddleNameProperty, kABPersonPrefixProperty, kABPersonSuffixProperty,
        kABPersonNicknameProperty, kABPersonOrganizationProperty, kABPersonDepartmentProperty,
        kABPersonJobTitleProperty, kABPersonNoteProperty, kABPersonFirstNamePhoneticProperty,
        kABPersonMiddleNamePhoneticProperty, kABPersonLastNamePhoneticProperty};
    NSArray *keys = [NSArray arrayWithObjects:@"first", @"last", @"middle", @"prefix", @"suffix",
        @"NICKNAME", @"organization", @"department", @"TITLE", @"NOTE", @"X-PHONETIC-FIRST-NAME",
        @"X-PHONETIC-MIDDLE-NAME", @"X-PHONETIC-LAST-NAME", nil];
    for (NSUInteger i = 0; i < [keys count]; i++) CopyProperty(contact, person, properties[i], [keys objectAtIndex:i]);
    NSDate *birthday = [(NSDate *)ABRecordCopyValue(person, kABPersonBirthdayProperty) autorelease];
    if (birthday != nil) [contact setObject:DateString(birthday, [NSTimeZone timeZoneForSecondsFromGMT:0]) forKey:@"BDAY"];
    NSNumber *kind = [(NSNumber *)ABRecordCopyValue(person, kABPersonKindProperty) autorelease];
    if ([kind isEqual:(NSNumber *)kABPersonKindOrganization]) [contact setObject:@"COMPANY" forKey:@"X-ABShowAs"];
    ABPropertyID multiProperties[] = {kABPersonPhoneProperty, kABPersonEmailProperty, kABPersonURLProperty,
        kABPersonAddressProperty, kABPersonDateProperty, kABPersonRelatedNamesProperty};
    keys = [NSArray arrayWithObjects:@"TEL", @"EMAIL", @"URL", @"ADR", @"X-ABDATE", @"X-ABRELATEDNAMES", nil];
    for (NSUInteger i = 0; i < [keys count]; i++) CopyMultiProperty(contact, person, multiProperties[i], [keys objectAtIndex:i]);
    CopyMultiProperty(contact, person, kABPersonInstantMessageProperty, @"im");
    NSDictionary *services = [NSDictionary dictionaryWithObjectsAndKeys:@"X-AIM", @"AIM", @"X-JABBER", @"Jabber",
        @"X-MSN", @"MSN", @"X-YAHOO", @"Yahoo", @"X-ICQ", @"ICQ", nil];
    for (NSDictionary *entry in [contact objectForKey:@"im"]) {
        NSDictionary *value = [entry objectForKey:@"value"];
        NSString *key = [services objectForKey:[value objectForKey:(NSString *)kABPersonInstantMessageServiceKey]];
        NSString *username = [value objectForKey:(NSString *)kABPersonInstantMessageUsernameKey];
        if (key != nil && username != nil) {
            NSMutableArray *entries = [contact objectForKey:key];
            if (entries == nil) {
                entries = [NSMutableArray array];
                [contact setObject:entries forKey:key];
            }
            [entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:username, @"value",
                [entry objectForKey:@"label"], @"label", nil]];
        }
    }
    NSData *photo = [(NSData *)ABPersonCopyImageDataWithFormat(person, kABPersonImageFormatOriginalSize) autorelease];
    if (photo != nil) [contact setObject:photo forKey:@"photo"];
    return [VCardWriter dataForContact:contact];
}

@interface ContactBackup ()
- (BOOL)isCancelled;
- (void)prepare;
- (void)finished:(NSDictionary *)result;
@end

@implementation ContactBackup
@synthesize delegate = _delegate, fileName = _fileName, errorMessage = _errorMessage, contactCount = _contactCount;

- (void)start {
    [NSThread detachNewThreadSelector:@selector(prepare) toTarget:self withObject:nil];
}
- (BOOL)isCancelled {
    @synchronized(self) { return _cancelled; }
}
- (void)cancel {
    @synchronized(self) { _cancelled = YES; }
    if (_filePath != nil) [[NSFileManager defaultManager] removeItemAtPath:_filePath error:NULL];
    [_filePath release];
    _filePath = nil;
}
- (NSString *)takeFilePath {
    NSString *path = [_filePath autorelease];
    _filePath = nil;
    return path;
}
- (void)prepare {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    CreateBookFunction createBook = (CreateBookFunction)dlsym(RTLD_DEFAULT, "ABAddressBookCreateWithOptions");
    RequestAccessFunction requestAccess = (RequestAccessFunction)dlsym(RTLD_DEFAULT, "ABAddressBookRequestAccessWithCompletion");
    CreateVCardFunction createVCard = (CreateVCardFunction)dlsym(RTLD_DEFAULT, "ABPersonCreateVCardRepresentationWithPeople");
    ABAddressBookRef book = createBook != NULL ? createBook(NULL, NULL) : ABAddressBookCreate();
    NSString *error = book == NULL ? @"Could not open contacts. Please try again." : nil;
    if (book != NULL && requestAccess != NULL && ![self isCancelled]) {
        NSCondition *condition = [[[NSCondition alloc] init] autorelease];
        NSMutableDictionary *access = [NSMutableDictionary dictionary];
        CFRetain(book); // The permission callback can outlive a cancelled export.
        requestAccess(book, ^(bool granted, CFErrorRef accessError) {
            [condition lock];
            [access setObject:[NSNumber numberWithBool:granted && accessError == NULL] forKey:@"granted"];
            [condition signal];
            [condition unlock];
            CFRelease(book);
        });
        [condition lock];
        while ([access objectForKey:@"granted"] == nil && ![self isCancelled]) {
            [condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        if (![[access objectForKey:@"granted"] boolValue])
            error = @"Allow DipolShare to access Contacts in Settings > Privacy > Contacts, then try again.";
        [condition unlock];
    }
    CFArrayRef people = error == nil && ![self isCancelled] ? ABAddressBookCopyArrayOfAllPeople(book) : NULL;
    if (error == nil && people == NULL && ![self isCancelled]) error = @"Could not read contacts. Please try again.";
    NSUInteger count = people != NULL ? (NSUInteger)CFArrayGetCount(people) : 0;
    if (error == nil && count == 0) error = @"No contacts to back up.";
    NSString *path = nil;
    int fd = -1;
    if (error == nil && ![self isCancelled]) {
        NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"LocalSend-Contacts-XXXXXX"];
        char *buffer = strdup([template fileSystemRepresentation]);
        fd = buffer != NULL ? mkstemp(buffer) : -1;
        if (fd >= 0) path = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
        free(buffer);
        if (fd < 0) error = @"Could not create the contact backup. Check free space and try again.";
    }
    for (NSUInteger i = 0; error == nil && i < count && ![self isCancelled]; i++) {
        NSAutoreleasePool *contactPool = [[NSAutoreleasePool alloc] init];
        ABRecordRef person = CFArrayGetValueAtIndex(people, i);
        NSData *data = createVCard != NULL
            ? [(NSData *)createVCard((CFArrayRef)[NSArray arrayWithObject:(id)person]) autorelease]
            : LegacyVCard(person);
        if ([data length] == 0) error = @"Could not export a contact. No backup was sent.";
        NSUInteger offset = 0;
        while (error == nil && offset < [data length] && ![self isCancelled]) {
            ssize_t written = write(fd, (const char *)[data bytes] + offset, MIN((NSUInteger)32768, [data length] - offset));
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) error = @"Could not save the contact backup. Check free space and try again.";
            else offset += (NSUInteger)written;
        }
        [contactPool drain];
    }
    if (fd >= 0 && close(fd) != 0 && error == nil) error = @"Could not finish saving the contact backup.";
    if (people != NULL) CFRelease(people);
    if (book != NULL) CFRelease(book);
    if ((error != nil || [self isCancelled]) && path != nil) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        path = nil;
    }
    NSDictionary *result = [NSDictionary dictionaryWithObjectsAndKeys:path ?: @"", @"path",
        error ?: @"", @"error", [NSNumber numberWithUnsignedInteger:count], @"count",
        [NSString stringWithFormat:@"Contacts-%@.vcf", DateString([NSDate date], [NSTimeZone localTimeZone])], @"name", nil];
    [self performSelectorOnMainThread:@selector(finished:) withObject:result waitUntilDone:NO];
    [pool drain];
}
- (void)finished:(NSDictionary *)result {
    NSString *path = [result objectForKey:@"path"];
    if ([self isCancelled]) {
        if ([path length]) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        return;
    }
    _filePath = [path length] ? [path copy] : nil;
    _fileName = [[result objectForKey:@"name"] copy];
    _errorMessage = [[result objectForKey:@"error"] copy];
    _contactCount = [[result objectForKey:@"count"] unsignedIntegerValue];
    [_delegate contactBackupDidFinish:self];
}
- (void)dealloc {
    [self cancel];
    [_fileName release];
    [_errorMessage release];
    [super dealloc];
}
@end
