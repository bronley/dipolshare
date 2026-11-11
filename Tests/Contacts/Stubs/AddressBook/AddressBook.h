#import <Foundation/Foundation.h>
typedef CFTypeRef ABAddressBookRef;
typedef CFTypeRef ABRecordRef;
typedef CFTypeRef ABMultiValueRef;
typedef int ABPropertyID;
typedef int ABPersonImageFormat;
enum { kABPersonFirstNameProperty = 1, kABPersonLastNameProperty,
    kABPersonMiddleNameProperty, kABPersonPrefixProperty, kABPersonSuffixProperty,
    kABPersonNicknameProperty, kABPersonOrganizationProperty, kABPersonDepartmentProperty,
    kABPersonJobTitleProperty, kABPersonNoteProperty, kABPersonFirstNamePhoneticProperty,
    kABPersonMiddleNamePhoneticProperty, kABPersonLastNamePhoneticProperty,
    kABPersonBirthdayProperty, kABPersonKindProperty, kABPersonPhoneProperty,
    kABPersonEmailProperty, kABPersonURLProperty, kABPersonAddressProperty,
    kABPersonDateProperty, kABPersonRelatedNamesProperty, kABPersonInstantMessageProperty,
    kABPersonImageFormatOriginalSize };
#define kABPersonKindOrganization ((CFNumberRef)@1)
#define kABPersonInstantMessageServiceKey CFSTR("Service")
#define kABPersonInstantMessageUsernameKey CFSTR("Username")
ABAddressBookRef ABAddressBookCreate(void);
CFArrayRef ABAddressBookCopyArrayOfAllPeople(ABAddressBookRef book);
CFStringRef ABRecordCopyCompositeName(ABRecordRef person);
CFTypeRef ABRecordCopyValue(ABRecordRef person, ABPropertyID property);
CFIndex ABMultiValueGetCount(ABMultiValueRef values);
CFTypeRef ABMultiValueCopyValueAtIndex(ABMultiValueRef values, CFIndex index);
CFStringRef ABMultiValueCopyLabelAtIndex(ABMultiValueRef values, CFIndex index);
CFDataRef ABPersonCopyImageDataWithFormat(ABRecordRef person, ABPersonImageFormat format);
