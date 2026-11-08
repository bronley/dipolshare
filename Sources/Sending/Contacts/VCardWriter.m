#import "VCardWriter.h"

static NSString *Escape(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return @"";
    NSMutableString *text = [NSMutableString stringWithString:value];
    [text replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, [text length])];
    [text replaceOccurrencesOfString:@"\r\n" withString:@"\n" options:0 range:NSMakeRange(0, [text length])];
    [text replaceOccurrencesOfString:@"\r" withString:@"\n" options:0 range:NSMakeRange(0, [text length])];
    [text replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0, [text length])];
    [text replaceOccurrencesOfString:@";" withString:@"\\;" options:0 range:NSMakeRange(0, [text length])];
    [text replaceOccurrencesOfString:@"," withString:@"\\," options:0 range:NSMakeRange(0, [text length])];
    return text;
}

static void AppendLine(NSMutableData *output, NSString *line) {
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *bytes = [data bytes];
    NSUInteger offset = 0;
    do {
        NSUInteger limit = offset == 0 ? 75 : 74;
        NSUInteger end = MIN(offset + limit, [data length]);
        if (end < [data length]) {
            while (end > offset && (bytes[end] & 0xC0) == 0x80) end--;
        }
        if (offset > 0) [output appendBytes:" " length:1];
        [output appendBytes:bytes + offset length:end - offset];
        [output appendBytes:"\r\n" length:2];
        offset = end;
    } while (offset < [data length]);
}

static NSString *Components(NSDictionary *contact, NSArray *keys) {
    NSMutableArray *values = [NSMutableArray array];
    for (NSString *key in keys) [values addObject:Escape([contact objectForKey:key])];
    return [values componentsJoinedByString:@";"];
}

static NSString *Base64(NSData *data) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned char *bytes = [data bytes];
    NSMutableData *encoded = [NSMutableData data];
    for (NSUInteger i = 0; i < [data length]; i += 3) {
        NSUInteger remaining = [data length] - i;
        unsigned int bits = ((unsigned int)bytes[i]) << 16;
        if (remaining > 1) bits |= ((unsigned int)bytes[i + 1]) << 8;
        if (remaining > 2) bits |= bytes[i + 2];
        char block[] = {alphabet[bits >> 18], alphabet[(bits >> 12) & 63],
                        remaining > 1 ? alphabet[(bits >> 6) & 63] : '=',
                        remaining > 2 ? alphabet[bits & 63] : '='};
        [encoded appendBytes:block length:4];
    }
    return [[[NSString alloc] initWithData:encoded encoding:NSASCIIStringEncoding] autorelease];
}

@implementation VCardWriter
+ (NSData *)dataForContact:(NSDictionary *)contact {
    NSMutableData *output = [NSMutableData data];
    AppendLine(output, @"BEGIN:VCARD");
    AppendLine(output, @"VERSION:3.0");
    AppendLine(output, [@"N:" stringByAppendingString:Components(contact,
        [NSArray arrayWithObjects:@"last", @"first", @"middle", @"prefix", @"suffix", nil])]);
    NSString *name = [contact objectForKey:@"name"];
    AppendLine(output, [@"FN:" stringByAppendingString:Escape([name length] ? name : @"Unnamed contact")]);
    if ([[contact objectForKey:@"organization"] length] || [[contact objectForKey:@"department"] length]) {
        AppendLine(output, [@"ORG:" stringByAppendingString:Components(contact,
            [NSArray arrayWithObjects:@"organization", @"department", nil])]);
    }
    for (NSString *key in [NSArray arrayWithObjects:@"NICKNAME", @"TITLE", @"NOTE", @"BDAY",
                           @"X-PHONETIC-FIRST-NAME", @"X-PHONETIC-MIDDLE-NAME", @"X-PHONETIC-LAST-NAME",
                           @"X-ABShowAs", nil]) {
        NSString *value = [contact objectForKey:key];
        if ([value length]) AppendLine(output, [NSString stringWithFormat:@"%@:%@", key, Escape(value)]);
    }
    NSUInteger group = 0;
    for (NSString *key in [NSArray arrayWithObjects:@"TEL", @"EMAIL", @"URL", @"ADR", @"X-ABDATE",
                           @"X-ABRELATEDNAMES", @"X-AIM", @"X-JABBER", @"X-MSN", @"X-YAHOO", @"X-ICQ", nil]) {
        for (NSDictionary *entry in [contact objectForKey:key]) {
            NSString *value;
            if ([key isEqualToString:@"ADR"]) {
                value = Components([entry objectForKey:@"value"], [NSArray arrayWithObjects:
                    @"po", @"extended", @"Street", @"City", @"State", @"ZIP", @"Country", nil]);
            } else {
                value = Escape([entry objectForKey:@"value"]);
            }
            NSString *label = [entry objectForKey:@"label"];
            NSString *type = @"";
            if ([label isEqualToString:@"_$!<Home>!$_"]) type = @";TYPE=HOME";
            else if ([label isEqualToString:@"_$!<Work>!$_"]) type = @";TYPE=WORK";
            else if ([key isEqualToString:@"TEL"]) {
                if ([label isEqualToString:@"_$!<Mobile>!$_"] || [label isEqualToString:@"iPhone"])
                    type = @";TYPE=CELL";
                else if ([label isEqualToString:@"_$!<HomeFAX>!$_"]) type = @";TYPE=HOME,FAX";
                else if ([label isEqualToString:@"_$!<WorkFAX>!$_"]) type = @";TYPE=WORK,FAX";
                else if ([label isEqualToString:@"_$!<Pager>!$_"]) type = @";TYPE=PAGER";
                else if ([label isEqualToString:@"_$!<Main>!$_"]) type = @";TYPE=PREF";
            }
            group++;
            AppendLine(output, [NSString stringWithFormat:@"item%lu.%@%@:%@", (unsigned long)group, key, type, value]);
            if ([label length]) AppendLine(output, [NSString stringWithFormat:@"item%lu.X-ABLabel:%@",
                                                    (unsigned long)group, Escape(label)]);
            NSString *countryCode = [[entry objectForKey:@"value"] isKindOfClass:[NSDictionary class]]
                ? [[entry objectForKey:@"value"] objectForKey:@"CountryCode"] : nil;
            if ([countryCode length]) AppendLine(output, [NSString stringWithFormat:@"item%lu.X-ABADR:%@",
                (unsigned long)group, Escape(countryCode)]);
        }
    }
    NSData *photo = [contact objectForKey:@"photo"];
    if ([photo length]) {
        const unsigned char *bytes = [photo bytes];
        NSString *type = [photo length] >= 4 && bytes[0] == 0x89 && bytes[1] == 'P' ? @"PNG" : @"JPEG";
        AppendLine(output, [NSString stringWithFormat:@"PHOTO;ENCODING=b;TYPE=%@:%@", type, Base64(photo)]);
    }
    AppendLine(output, @"END:VCARD");
    return output;
}
@end
