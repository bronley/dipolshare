#import <Foundation/Foundation.h>
#import <Contacts/Contacts.h>
#import <AddressBook/AddressBook.h>
#import "ContactBackup.h"
#import "VCardWriter.h"
#import <sys/stat.h>

static NSArray *People;
static BOOL NativeExport, NativeFailure, Denied, PermissionAPI, MissingBook, DelayPermission;
static NSUInteger NativeCalls, PeopleReads, FailureCount, TestCount;
static NSCondition *PermissionCondition;
static void (^PendingPermission)(bool, CFErrorRef);

static void Check(BOOL condition, const char *description) {
    TestCount++;
    if (!condition) FailureCount++;
    printf("%s %s\n", condition ? "PASS" : "FAIL", description);
}
ABAddressBookRef ABAddressBookCreate(void) { return MissingBook ? NULL : CFRetain((CFTypeRef)People); }
CFArrayRef ABAddressBookCopyArrayOfAllPeople(ABAddressBookRef book) {
    PeopleReads++;
    return CFRetain(book);
}
CFStringRef ABRecordCopyCompositeName(ABRecordRef person) {
    id value = [(NSDictionary *)person objectForKey:@"name"];
    return value != nil ? CFRetain((CFStringRef)value) : NULL;
}
CFTypeRef ABRecordCopyValue(ABRecordRef person, ABPropertyID property) {
    id value = [(NSDictionary *)person objectForKey:[NSNumber numberWithInt:property]];
    return value != nil ? CFRetain((CFTypeRef)value) : NULL;
}
CFIndex ABMultiValueGetCount(ABMultiValueRef values) { return [(NSArray *)values count]; }
CFTypeRef ABMultiValueCopyValueAtIndex(ABMultiValueRef values, CFIndex index) {
    return CFRetain((CFTypeRef)[[(NSArray *)values objectAtIndex:index] objectForKey:@"value"]);
}
CFStringRef ABMultiValueCopyLabelAtIndex(ABMultiValueRef values, CFIndex index) {
    return CFRetain((CFStringRef)[[(NSArray *)values objectAtIndex:index] objectForKey:@"label"]);
}
CFDataRef ABPersonCopyImageDataWithFormat(ABRecordRef person, ABPersonImageFormat format) { return NULL; }
static ABAddressBookRef CreateBook(CFDictionaryRef options, CFErrorRef *error) { return ABAddressBookCreate(); }
static void RequestAccess(ABAddressBookRef book, void (^completion)(bool, CFErrorRef)) {
    if (DelayPermission) {
        [PermissionCondition lock];
        PendingPermission = [completion copy];
        [PermissionCondition signal];
        [PermissionCondition unlock];
    } else completion(!Denied, NULL);
}
static CFDataRef NativeVCard(CFArrayRef people) {
    NativeCalls++;
    if (NativeFailure) return NULL;
    NSCAssert(CFArrayGetCount(people) == 1, @"Export one contact at a time");
    return (CFDataRef)[[@"BEGIN:VCARD\r\nVERSION:3.0\r\nN:;Native;;;\r\nFN:Native\r\nEND:VCARD\r\n"
        dataUsingEncoding:NSUTF8StringEncoding] retain];
}
void *ContactTestLookup(void *handle, const char *symbol) {
    if (strcmp(symbol, "ABAddressBookCreateWithOptions") == 0) return PermissionAPI ? CreateBook : NULL;
    if (strcmp(symbol, "ABAddressBookRequestAccessWithCompletion") == 0) return PermissionAPI ? RequestAccess : NULL;
    if (strcmp(symbol, "ABPersonCreateVCardRepresentationWithPeople") == 0) return NativeExport ? NativeVCard : NULL;
    return NULL;
}

@interface Observer : NSObject <ContactBackupDelegate> { @public BOOL done; BOOL onMain; }
@end
@implementation Observer
- (void)contactBackupDidFinish:(ContactBackup *)backup { done = YES; onMain = [NSThread isMainThread]; }
@end

static void Pump(NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
static ContactBackup *Export(Observer *observer) {
    observer->done = NO;
    ContactBackup *backup = [[ContactBackup alloc] init];
    backup.delegate = observer;
    [backup start];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
    while (!observer->done && [deadline timeIntervalSinceNow] > 0) Pump(0.005);
    Check(observer->done && observer->onMain, "export delivers its result on the main thread");
    return backup;
}

static void TestWriter(void) {
    NSString *note = @"First; comma, slash\\\r\nBEGIN:VCARD\nПривіт 👋";
    NSMutableString *name = [NSMutableString stringWithString:@"Zoë "];
    for (NSUInteger i = 0; i < 35; i++) [name appendString:@"界👋"];
    NSDictionary *contact = @{@"name":name, @"first":@"Zoë", @"last":@"Comma, Semi; Slash\\",
        @"NOTE":note, @"BDAY":@"1988-02-29", @"organization":@"A;B", @"department":@"R&D",
        @"TEL":@[@{@"value":@"+49 123 456", @"label":@"_$!<Mobile>!$_"}],
        @"EMAIL":@[@{@"value":@"zoe@example.com", @"label":@"Personal\nTEL:injected"}],
        @"ADR":@[@{@"value":@{@"Street":@"Line 1\nLine 2", @"City":@"Berlin", @"ZIP":@"10115", @"Country":@"Germany"}, @"label":@"_$!<Home>!$_"}]};
    NSData *data = [VCardWriter dataForContact:contact];
    NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    BOOL linesValid = YES;
    for (NSString *line in [text componentsSeparatedByString:@"\r\n"])
        linesValid &= [[line dataUsingEncoding:NSUTF8StringEncoding] length] <= 75;
    Check(linesValid, "vCard folding respects 75 UTF-8 octets without splitting Unicode");
    Check([text rangeOfString:@"\r\nTEL:injected"].location == NSNotFound &&
          [text rangeOfString:@"\r\nBEGIN:VCARD\r\n"].location == NSNotFound,
          "newlines in notes and custom labels cannot inject vCard properties");
    NSError *error = nil;
    NSArray *parsed = [CNContactVCardSerialization contactsWithData:data error:&error];
    Check([parsed count] == 1 && error == nil, "independent Apple Contacts parser accepts fallback vCard");
    CNContact *result = [parsed firstObject];
    Check([result.givenName isEqual:@"Zoë"] && [result.familyName isEqual:@"Comma, Semi; Slash\\"] &&
          [result.organizationName isEqual:@"A;B"] && [result.departmentName isEqual:@"R&D"],
          "names and structured company values round-trip punctuation and Unicode");
    Check([[[result.phoneNumbers firstObject] value].stringValue isEqual:@"+49 123 456"] &&
          [[[result.emailAddresses firstObject] value] isEqual:@"zoe@example.com"] &&
          [[[[result.postalAddresses firstObject] value] street] isEqual:@"Line 1\nLine 2"] &&
          result.birthday.year == 1988 && result.birthday.month == 2 && result.birthday.day == 29,
          "phones, emails, multiline addresses and leap-day birthdays round-trip");
    for (NSUInteger length = 1; length < 9; length++) {
        NSMutableData *photo = [NSMutableData dataWithLength:length];
        for (NSUInteger i = 0; i < length; i++) ((unsigned char *)[photo mutableBytes])[i] = i * 29;
        NSData *card = [VCardWriter dataForContact:@{@"name":@"Photo", @"photo":photo}];
        NSString *content = [[[NSString alloc] initWithData:card encoding:NSUTF8StringEncoding] autorelease];
        NSString *unfolded = [content stringByReplacingOccurrencesOfString:@"\r\n " withString:@""];
        Check([unfolded rangeOfString:[photo base64EncodedStringWithOptions:0]].location != NSNotFound,
              "photo base64 preserves bytes and padding");
    }
}

static void TestExport(void) {
    People = @[@{@"name":@"Zoë", @(kABPersonFirstNameProperty):@"Zoë",
                @(kABPersonPhoneProperty):@[@{@"value":@"+49 123", @"label":@"_$!<Mobile>!$_"}]},
               @{@"name":@"Олена", @(kABPersonFirstNameProperty):@"Олена"}];
    Observer *observer = [[[Observer alloc] init] autorelease];
    ContactBackup *backup = Export(observer);
    NSString *path = [[backup takeFilePath] retain];
    struct stat attributes;
    Check(backup.contactCount == 2 && [backup.errorMessage length] == 0 && path != nil &&
          stat([path fileSystemRepresentation], &attributes) == 0 && (attributes.st_mode & 0777) == 0600,
          "legacy export snapshots every contact into a private temporary file");
    NSData *data = [NSData dataWithContentsOfFile:path];
    Check([[CNContactVCardSerialization contactsWithData:data error:NULL] count] == 2,
          "combined backup imports as two contacts");
    Check([backup.fileName hasPrefix:@"Contacts-"] && [[backup.fileName pathExtension] isEqual:@"vcf"],
          "backup has a dated vcf filename");
    [backup release];
    Check([[NSFileManager defaultManager] fileExistsAtPath:path], "taking the file transfers cleanup responsibility to sender");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    [path release];

    backup = Export(observer);
    path = [[backup valueForKey:@"filePath"] copy];
    [backup cancel];
    Check(![[NSFileManager defaultManager] fileExistsAtPath:path] && [backup takeFilePath] == nil,
          "cancelling the confirmation removes the prepared snapshot");
    [backup release]; [path release];

    NativeExport = YES; PermissionAPI = YES;
    backup = Export(observer);
    Check(NativeCalls == 2 && backup.contactCount == 2 && [backup.errorMessage length] == 0,
          "iOS 5+ uses native vCard export one person at a time");
    [backup release];
    Denied = YES;
    NSUInteger reads = PeopleReads;
    backup = Export(observer);
    Check([backup.errorMessage rangeOfString:@"Privacy"].location != NSNotFound &&
          [backup takeFilePath] == nil && PeopleReads == reads,
          "denied permission never reads people or produces a backup");
    [backup release]; Denied = NO;
    NativeFailure = YES;
    backup = Export(observer);
    Check([backup.errorMessage length] > 0 && [backup takeFilePath] == nil,
          "failed native export discards the incomplete backup");
    [backup release]; NativeFailure = NO;
    MissingBook = YES;
    backup = Export(observer);
    Check([backup.errorMessage length] > 0 && [backup takeFilePath] == nil, "address book open failure is reported");
    [backup release]; MissingBook = NO;
    People = @[];
    backup = Export(observer);
    Check([backup.errorMessage isEqual:@"No contacts to back up."] && [backup takeFilePath] == nil,
          "empty address book cannot create an empty backup");
    [backup release];

    DelayPermission = YES;
    PermissionCondition = [[NSCondition alloc] init];
    observer->done = NO;
    backup = [[ContactBackup alloc] init]; backup.delegate = observer;
    [backup start];
    [PermissionCondition lock];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
    while (PendingPermission == nil && [deadline timeIntervalSinceNow] > 0) [PermissionCondition waitUntilDate:deadline];
    Check(PendingPermission != nil, "permission request can remain pending without blocking main UI");
    [PermissionCondition unlock];
    [backup cancel]; [backup release];
    Pump(0.2);
    [PermissionCondition lock];
    if (PendingPermission != nil) { PendingPermission(true, NULL); [PendingPermission release]; PendingPermission = nil; }
    [PermissionCondition unlock];
    Pump(0.2);
    Check(!observer->done, "late permission callback after cancellation cannot present confirmation");
    [PermissionCondition release]; PermissionCondition = nil;
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    TestWriter();
    TestExport();
    printf("%lu/%lu checks passed\n", (unsigned long)(TestCount - FailureCount), (unsigned long)TestCount);
    [pool drain];
    return FailureCount ? 1 : 0;
}
