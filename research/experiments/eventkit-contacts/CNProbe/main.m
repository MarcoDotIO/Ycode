// CNProbe: our own black-box probe of Contacts / ContactsUI in the iOS simulator.
// Written for Ycode's clean-room specs (specs/frameworks/contacts/). Public API
// only; every person, address and number below is made up. Output: one line
// per observation on stderr, prefixed "CNPROBE", ending with "phase <p> DONE".
//
//   -phase basic    no access needed: constants, labels, formatter and postal
//                   goldens, vCard export/import, exceptions, errors
//   -phase req      requestAccessForEntityType (system prompt)
//   -phase noaccess store calls without asking first (implicit prompt)
//   -phase status   status only
//   -phase data     containers, groups, CRUD, predicates, key descriptors,
//                   unification flags, change history, notifications, errors
//   -phase list     every visible contact (name, identifier, container)
//   -phase count    count the probe's contacts (persistence check)
//   -phase wipe     delete the probe's contacts and groups
//   -phase uipicker present CNContactPickerViewController (no access needed)
//   -phase uinew    present CNContactViewController for a new contact
//   -phase uiunknown present CNContactViewController for an unknown contact
#import <UIKit/UIKit.h>
#import <Contacts/Contacts.h>
#import <ContactsUI/ContactsUI.h>
#import <QuartzCore/QuartzCore.h>

static CFTimeInterval gStart;
static CNContactStore *gStore;
static UIViewController *gRoot;

static void P(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void P(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    fprintf(stderr, "CNPROBE t=%.3f %s\n", CACurrentMediaTime() - gStart, s.UTF8String);
    fflush(stderr);
}
static NSString *E(NSError *e) {
    if (!e) return @"nil";
    NSMutableArray *keys = [NSMutableArray array];
    for (id k in e.userInfo) [keys addObject:[k description]];
    [keys sortUsingSelector:@selector(compare:)];
    NSMutableString *s = [NSMutableString stringWithFormat:@"{domain=%@ code=%ld keys=[%@] desc=\"%@\"", e.domain, (long)e.code,
                          [keys componentsJoinedByString:@","], e.localizedDescription];
    NSArray *sub = e.userInfo[CNErrorUserInfoValidationErrorsKey];
    for (NSError *x in sub) [s appendFormat:@" sub=%@", E(x)];
    id kp = e.userInfo[CNErrorUserInfoKeyPathsKey];
    if (kp) [s appendFormat:@" keyPaths=%@", [kp description]];
    id ai = e.userInfo[CNErrorUserInfoAffectedRecordIdentifiersKey];
    if (ai) [s appendFormat:@" affectedIds=%lu", (unsigned long)[ai count]];
    [s appendString:@"}"];
    return s;
}
static NSString *Thr(void) {
    const char *l = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    return [NSString stringWithFormat:@"main=%d q=%s", [NSThread isMainThread], l ? l : "?"];
}
static void Sleep(double s) { [NSThread sleepForTimeInterval:s]; }
static NSString *Q(NSString *s) { return s ? [NSString stringWithFormat:@"\"%@\"", s] : @"nil"; }
static NSString *Strip(NSString *d) {
    NSRegularExpression *r = [NSRegularExpression regularExpressionWithPattern:@"0x[0-9a-f]+" options:0 error:nil];
    return [r stringByReplacingMatchesInString:d options:0 range:NSMakeRange(0, d.length) withTemplate:@"0x…"];
}
static NSDateComponents *DCx(NSInteger y, NSInteger m, NSInteger d) {
    NSDateComponents *c = [NSDateComponents new];
    if (y) c.year = y;
    c.month = m; c.day = d;
    return c;
}
static NSString *DCs(NSDateComponents *c) {
    if (!c) return @"nil";
    return [NSString stringWithFormat:@"%@%ld-%ld-%ld", c.calendar ? [c.calendar.calendarIdentifier stringByAppendingString:@":"] : @"",
            (long)(c.year == NSDateComponentUndefined ? 0 : c.year), (long)c.month, (long)c.day];
}

static NSArray *AllKeys(BOOL notes) {
    NSMutableArray *a = [@[ CNContactIdentifierKey, CNContactTypeKey, CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey,
                            CNContactFamilyNameKey, CNContactPreviousFamilyNameKey, CNContactNameSuffixKey, CNContactNicknameKey,
                            CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey, CNContactPhoneticGivenNameKey,
                            CNContactPhoneticMiddleNameKey, CNContactPhoneticFamilyNameKey, CNContactPhoneticOrganizationNameKey,
                            CNContactBirthdayKey, CNContactNonGregorianBirthdayKey, CNContactImageDataKey, CNContactThumbnailImageDataKey,
                            CNContactImageDataAvailableKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey,
                            CNContactDatesKey, CNContactUrlAddressesKey, CNContactRelationsKey, CNContactSocialProfilesKey,
                            CNContactInstantMessageAddressesKey ] mutableCopy];
    if (notes) [a addObject:CNContactNoteKey];
    return a;
}

static NSString *LV(NSArray<CNLabeledValue *> *a) {
    NSMutableArray *o = [NSMutableArray array];
    for (CNLabeledValue *lv in a) {
        id v = lv.value; NSString *vs;
        if ([v isKindOfClass:[CNPhoneNumber class]]) vs = [v stringValue];
        else if ([v isKindOfClass:[CNPostalAddress class]]) vs = [[CNPostalAddressFormatter stringFromPostalAddress:v style:CNPostalAddressFormatterStyleMailingAddress] stringByReplacingOccurrencesOfString:@"\n" withString:@" | "];
        else if ([v isKindOfClass:[CNContactRelation class]]) vs = [v name];
        else if ([v isKindOfClass:[CNSocialProfile class]]) vs = [NSString stringWithFormat:@"%@/%@/%@/%@", [v service], [v username], [v urlString], [v userIdentifier]];
        else if ([v isKindOfClass:[CNInstantMessageAddress class]]) vs = [NSString stringWithFormat:@"%@/%@", [v service], [v username]];
        else if ([v isKindOfClass:[NSDateComponents class]]) vs = DCs(v);
        else vs = [v description];
        [o addObject:[NSString stringWithFormat:@"%@=%@", lv.label ?: @"nil", vs]];
    }
    return [NSString stringWithFormat:@"[%@]", [o componentsJoinedByString:@"; "]];
}

static NSString *CDesc(CNContact *c) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"type=%ld", (long)c.contactType];
    for (NSString *k in @[ CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactPreviousFamilyNameKey,
                           CNContactNameSuffixKey, CNContactNicknameKey, CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey,
                           CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey, CNContactPhoneticFamilyNameKey, CNContactPhoneticOrganizationNameKey ])
        if ([c isKeyAvailable:k] && [[c valueForKey:k] length]) [s appendFormat:@" %@=%@", k, Q([c valueForKey:k])];
    if ([c isKeyAvailable:CNContactBirthdayKey] && c.birthday) [s appendFormat:@" birthday=%@", DCs(c.birthday)];
    if ([c isKeyAvailable:CNContactNonGregorianBirthdayKey] && c.nonGregorianBirthday) [s appendFormat:@" nonGregorianBirthday=%@", DCs(c.nonGregorianBirthday)];
    if ([c isKeyAvailable:CNContactPhoneNumbersKey] && c.phoneNumbers.count) [s appendFormat:@" phones=%@", LV(c.phoneNumbers)];
    if ([c isKeyAvailable:CNContactEmailAddressesKey] && c.emailAddresses.count) [s appendFormat:@" emails=%@", LV(c.emailAddresses)];
    if ([c isKeyAvailable:CNContactPostalAddressesKey] && c.postalAddresses.count) [s appendFormat:@" postal=%@", LV(c.postalAddresses)];
    if ([c isKeyAvailable:CNContactUrlAddressesKey] && c.urlAddresses.count) [s appendFormat:@" urls=%@", LV(c.urlAddresses)];
    if ([c isKeyAvailable:CNContactDatesKey] && c.dates.count) [s appendFormat:@" dates=%@", LV(c.dates)];
    if ([c isKeyAvailable:CNContactRelationsKey] && c.contactRelations.count) [s appendFormat:@" relations=%@", LV(c.contactRelations)];
    if ([c isKeyAvailable:CNContactSocialProfilesKey] && c.socialProfiles.count) [s appendFormat:@" social=%@", LV(c.socialProfiles)];
    if ([c isKeyAvailable:CNContactInstantMessageAddressesKey] && c.instantMessageAddresses.count) [s appendFormat:@" im=%@", LV(c.instantMessageAddresses)];
    if ([c isKeyAvailable:CNContactNoteKey] && c.note.length) [s appendFormat:@" note=%@", Q(c.note)];
    if ([c isKeyAvailable:CNContactImageDataKey]) [s appendFormat:@" image=%lu", (unsigned long)c.imageData.length];
    if ([c isKeyAvailable:CNContactThumbnailImageDataKey]) [s appendFormat:@" thumb=%lu", (unsigned long)c.thumbnailImageData.length];
    if ([c isKeyAvailable:CNContactImageDataAvailableKey]) [s appendFormat:@" imageAvailable=%d", c.imageDataAvailable];
    return s;
}

static CNLabeledValue *L(NSString *label, id v) { return [CNLabeledValue labeledValueWithLabel:label value:v]; }
static CNPhoneNumber *Ph(NSString *s) { return [CNPhoneNumber phoneNumberWithStringValue:s]; }
static CNMutablePostalAddress *Addr(NSString *street, NSString *subLoc, NSString *city, NSString *subAdmin, NSString *state, NSString *zip,
                                    NSString *country, NSString *iso) {
    CNMutablePostalAddress *a = [CNMutablePostalAddress new];
    a.street = street ?: @""; a.subLocality = subLoc ?: @""; a.city = city ?: @""; a.subAdministrativeArea = subAdmin ?: @"";
    a.state = state ?: @""; a.postalCode = zip ?: @""; a.country = country ?: @""; a.ISOCountryCode = iso ?: @"";
    return a;
}

static NSData *TinyPNG(void) {
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat];
    f.scale = 1;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(4, 4) format:f];
    return [r PNGDataWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor colorWithRed:0.2 green:0.4 blue:0.6 alpha:1] setFill];
        [ctx fillRect:CGRectMake(0, 0, 4, 4)];
    }];
}

// The full made-up contact used by the vCard and store tests.
static CNMutableContact *Full(NSString *given, NSString *family) {
    CNMutableContact *c = [CNMutableContact new];
    c.namePrefix = @"Dr."; c.givenName = given; c.middleName = @"Quinn"; c.familyName = family; c.nameSuffix = @"Jr.";
    c.previousFamilyName = @"Sample"; c.nickname = @"Ave";
    c.organizationName = @"Example Widgets LLC"; c.departmentName = @"Research"; c.jobTitle = @"Prober";
    c.phoneticGivenName = @"AY-ver-ee"; c.phoneticFamilyName = @"ig-ZAM-pul";
    c.phoneNumbers = @[ L(CNLabelPhoneNumberMobile, Ph(@"+1 (555) 010-0001")), L(CNLabelHome, Ph(@"555-010-0002")),
                        L(CNLabelPhoneNumberiPhone, Ph(@"5550100003")), L(CNLabelWork, Ph(@"+44 20 7946 0000")),
                        L(@"Probe custom", Ph(@"555 010 0004")), L(CNLabelPhoneNumberHomeFax, Ph(@"555-010-0005")) ];
    c.emailAddresses = @[ L(CNLabelHome, @"avery@example.com"), L(CNLabelWork, @"avery.example@example.org"), L(CNLabelEmailiCloud, @"avery@example.net") ];
    c.postalAddresses = @[ L(CNLabelHome, Addr(@"123 Example Street\nApt 4", nil, @"Springfield", nil, @"IL", @"62701", @"United States", @"us")),
                           L(CNLabelWork, Addr(@"Beispielstraße 5", nil, @"Berlin", nil, nil, @"10115", @"Germany", @"de")) ];
    c.urlAddresses = @[ L(CNLabelURLAddressHomePage, @"https://example.com/avery"), L(CNLabelWork, @"https://example.org") ];
    c.birthday = DCx(1990, 3, 15);
    NSDateComponents *ng = DCx(0, 0, 0);
    ng.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierHebrew]; ng.year = 5750; ng.month = 7; ng.day = 18;
    c.nonGregorianBirthday = ng;
    c.dates = @[ L(CNLabelDateAnniversary, DCx(2015, 6, 20)), L(CNLabelOther, DCx(0, 12, 1)) ];
    c.contactRelations = @[ L(CNLabelContactRelationSpouse, [CNContactRelation contactRelationWithName:@"Robin Example"]),
                            L(CNLabelContactRelationManager, [CNContactRelation contactRelationWithName:@"Morgan Sample"]) ];
    c.socialProfiles = @[ L(nil, [[CNSocialProfile alloc] initWithUrlString:nil username:@"averyprobe" userIdentifier:nil service:CNSocialProfileServiceTwitter]),
                          L(nil, [[CNSocialProfile alloc] initWithUrlString:@"https://social.example/avery" username:@"avery" userIdentifier:@"42" service:@"ExampleSocial"]) ];
    c.instantMessageAddresses = @[ L(CNLabelHome, [[CNInstantMessageAddress alloc] initWithUsername:@"avery.im" service:CNInstantMessageServiceJabber]),
                                   L(CNLabelWork, [[CNInstantMessageAddress alloc] initWithUsername:@"averyq" service:@"ExampleChat"]) ];
    return c;
}

#pragma mark - basic

static void Constants(void) {
#define X(n) P(@"const %s=%@", #n, Q((NSString *)n));
#include "consts.inc"
#undef X
}

static void Labels(void) {
    NSArray *labels = @[ CNLabelHome, CNLabelWork, CNLabelSchool, CNLabelOther, CNLabelEmailiCloud, CNLabelURLAddressHomePage, CNLabelDateAnniversary,
                         CNLabelPhoneNumberiPhone, CNLabelPhoneNumberMobile, CNLabelPhoneNumberMain, CNLabelPhoneNumberHomeFax, CNLabelPhoneNumberWorkFax,
                         CNLabelPhoneNumberOtherFax, CNLabelPhoneNumberPager, CNLabelPhoneNumberAppleWatch, CNLabelContactRelationFather,
                         CNLabelContactRelationMother, CNLabelContactRelationSpouse, CNLabelContactRelationManager, CNLabelContactRelationDaughterInLaw,
                         @"Probe custom", @"" ];
    for (NSString *l in labels) P(@"label %@ -> localized %@", Q(l), Q([CNLabeledValue localizedStringForLabel:l]));
    for (NSString *k in AllKeys(YES)) P(@"contact key %@ -> localized %@", k, Q([CNContact localizedStringForKey:k]));
    for (NSString *k in @[ CNPostalAddressStreetKey, CNPostalAddressSubLocalityKey, CNPostalAddressCityKey, CNPostalAddressSubAdministrativeAreaKey,
                           CNPostalAddressStateKey, CNPostalAddressPostalCodeKey, CNPostalAddressCountryKey, CNPostalAddressISOCountryCodeKey ])
        P(@"postal key %@ -> localized %@", k, Q([CNPostalAddress localizedStringForKey:k]));
    for (NSString *s in @[ CNSocialProfileServiceTwitter, CNSocialProfileServiceFacebook, CNSocialProfileServiceLinkedIn, @"ExampleSocial" ])
        P(@"social service %@ -> %@", s, Q([CNSocialProfile localizedStringForService:s]));
    for (NSString *s in @[ CNInstantMessageServiceJabber, CNInstantMessageServiceAIM, CNInstantMessageServiceSkype, @"ExampleChat" ])
        P(@"im service %@ -> %@", s, Q([CNInstantMessageAddress localizedStringForService:s]));
    CNLabeledValue *lv = L(CNLabelHome, @"x@example.com");
    CNLabeledValue *lv2 = [lv labeledValueBySettingLabel:CNLabelWork];
    P(@"labeledValue identifier nonnil=%d settingLabel keeps id=%d equal=%d", lv.identifier.length > 0, [lv.identifier isEqualToString:lv2.identifier], [lv isEqual:lv2]);
    P(@"labeledValue identifier format example=%@", lv.identifier);
}

static void Fmt(NSString *tag, CNContact *c) {
    NSString *full = [CNContactFormatter stringFromContact:c style:CNContactFormatterStyleFullName];
    NSString *ph = [CNContactFormatter stringFromContact:c style:CNContactFormatterStylePhoneticFullName];
    NSAttributedString *as = [CNContactFormatter attributedStringFromContact:c style:CNContactFormatterStyleFullName defaultAttributes:nil];
    NSMutableArray *runs = [NSMutableArray array];
    [as enumerateAttribute:CNContactPropertyAttribute inRange:NSMakeRange(0, as.length) options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
        [runs addObject:[NSString stringWithFormat:@"%@:%@", Q([as.string substringWithRange:r]), v ?: @"-"]];
    }];
    P(@"fmt %@ full=%@ phonetic=%@ order=%ld delimiter=%@ runs=[%@]", tag, Q(full), Q(ph), (long)[CNContactFormatter nameOrderForContact:c],
      Q([CNContactFormatter delimiterForContact:c]), [runs componentsJoinedByString:@" "]);
}

static CNMutableContact *Name(NSString *prefix, NSString *given, NSString *middle, NSString *family, NSString *suffix, NSString *nick, NSString *org) {
    CNMutableContact *c = [CNMutableContact new];
    c.namePrefix = prefix ?: @""; c.givenName = given ?: @""; c.middleName = middle ?: @""; c.familyName = family ?: @"";
    c.nameSuffix = suffix ?: @""; c.nickname = nick ?: @""; c.organizationName = org ?: @"";
    return c;
}

static void Formatters(void) {
    Fmt(@"F1 given+family", Name(nil, @"Avery", nil, @"Example", nil, nil, nil));
    Fmt(@"F2 all parts", Name(@"Dr.", @"Avery", @"Quinn", @"Example", @"Jr.", @"Ave", @"Example Widgets LLC"));
    Fmt(@"F3 given only", Name(nil, @"Avery", nil, nil, nil, nil, nil));
    Fmt(@"F4 family only", Name(nil, nil, nil, @"Example", nil, nil, nil));
    Fmt(@"F5 middle only", Name(nil, nil, @"Quinn", nil, nil, nil, nil));
    Fmt(@"F6 nickname only", Name(nil, nil, nil, nil, nil, @"Ave", nil));
    Fmt(@"F7 org only (person)", Name(nil, nil, nil, nil, nil, nil, @"Example Widgets LLC"));
    CNMutableContact *o = Name(nil, @"Avery", nil, @"Example", nil, nil, @"Example Widgets LLC"); o.contactType = CNContactTypeOrganization;
    Fmt(@"F8 organization type", o);
    Fmt(@"F9 prefix+family", Name(@"Ms.", nil, nil, @"Example", nil, nil, nil));
    Fmt(@"F10 given+suffix", Name(nil, @"Avery", nil, nil, @"III", nil, nil));
    Fmt(@"F11 japanese", Name(nil, @"太郎", nil, @"山田", nil, nil, nil));
    Fmt(@"F12 chinese", Name(nil, @"小明", nil, @"王", nil, nil, nil));
    Fmt(@"F13 korean", Name(nil, @"민준", nil, @"김", nil, nil, nil));
    Fmt(@"F14 latin accents", Name(nil, @"José", @"Luis", @"García", nil, nil, nil));
    Fmt(@"F15 japanese given latin family", Name(nil, @"太郎", nil, @"Example", nil, nil, nil));
    Fmt(@"F16 latin given japanese family", Name(nil, @"Avery", nil, @"山田", nil, nil, nil));
    Fmt(@"F17 empty", Name(nil, nil, nil, nil, nil, nil, nil));
    CNMutableContact *em = [CNMutableContact new];
    em.emailAddresses = @[ L(CNLabelHome, @"only@example.com") ];
    Fmt(@"F18 email only", em);
    CNMutableContact *p = Name(nil, @"Avery", nil, @"Example", nil, nil, nil);
    p.phoneticGivenName = @"AY-ver-ee"; p.phoneticFamilyName = @"ig-ZAM-pul"; p.phoneticMiddleName = @"kwin";
    Fmt(@"F19 phonetic", p);
    CNMutableContact *jp = Name(nil, @"太郎", nil, @"山田", nil, nil, nil);
    jp.phoneticGivenName = @"たろう"; jp.phoneticFamilyName = @"やまだ";
    Fmt(@"F20 japanese phonetic", jp);
    CNMutableContact *op = Name(nil, nil, nil, nil, nil, nil, @"Example Widgets LLC"); op.contactType = CNContactTypeOrganization;
    op.phoneticOrganizationName = @"ig-ZAM-pul WID-jits";
    Fmt(@"F21 org phonetic", op);
    Fmt(@"F22 spaces", Name(nil, @" Avery ", nil, @"Example  ", nil, nil, nil));
    Fmt(@"F23 arabic", Name(nil, @"سارة", nil, @"مثال", nil, nil, nil));
    Fmt(@"F24 russian", Name(nil, @"Анна", @"Ивановна", @"Пример", nil, nil, nil));
    // Missing-key behaviour: a partially fetched contact cannot be built locally; descriptor names instead.
    id<CNKeyDescriptor> d = [CNContactFormatter descriptorForRequiredKeysForStyle:CNContactFormatterStyleFullName];
    P(@"fmt descriptorForRequiredKeysForStyle(full) desc=%@", Strip([(NSObject *)d description]));
    P(@"fmt descriptorForRequiredKeysForNameOrder desc=%@", Strip([(NSObject *)[CNContactFormatter descriptorForRequiredKeysForNameOrder] description]));
    P(@"fmt descriptorForRequiredKeysForDelimiter desc=%@", Strip([(NSObject *)[CNContactFormatter descriptorForRequiredKeysForDelimiter] description]));
    // Sort comparator.
    NSArray *people = @[ Name(nil, @"bob", nil, @"Zed", nil, nil, nil), Name(nil, @"Alice", nil, @"young", nil, nil, nil), Name(nil, @"Émile", nil, @"Xavier", nil, nil, nil),
                         Name(nil, nil, nil, nil, nil, nil, @"Acme Org"), Name(nil, @"alice", nil, @"Adams", nil, nil, nil), Name(nil, @"山田", nil, @"太郎", nil, nil, nil) ];
    for (NSNumber *o2 in @[ @(CNContactSortOrderGivenName), @(CNContactSortOrderFamilyName), @(CNContactSortOrderUserDefault), @(CNContactSortOrderNone) ]) {
        NSArray *s = [people sortedArrayUsingComparator:[CNContact comparatorForNameSortOrder:o2.integerValue]];
        NSMutableArray *n = [NSMutableArray array];
        for (CNContact *c in s) [n addObject:[NSString stringWithFormat:@"%@/%@/%@", c.givenName, c.familyName, c.organizationName]];
        P(@"sort order=%@ -> %@", o2, [n componentsJoinedByString:@", "]);
    }
    P(@"descriptorForAllComparatorKeys=%@", Strip([(NSObject *)[CNContact descriptorForAllComparatorKeys] description]));
    CNContactsUserDefaults *ud = [CNContactsUserDefaults sharedDefaults];
    P(@"userDefaults sortOrder=%ld countryCode=%@", (long)ud.sortOrder, ud.countryCode);
}

static void PFmt(NSString *tag, CNPostalAddress *a) {
    NSString *s = [CNPostalAddressFormatter stringFromPostalAddress:a style:CNPostalAddressFormatterStyleMailingAddress];
    NSAttributedString *as = [CNPostalAddressFormatter attributedStringFromPostalAddress:a style:CNPostalAddressFormatterStyleMailingAddress withDefaultAttributes:@{}];
    NSMutableArray *runs = [NSMutableArray array];
    [as enumerateAttribute:CNPostalAddressPropertyAttribute inRange:NSMakeRange(0, as.length) options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
        if (v) [runs addObject:[NSString stringWithFormat:@"%@:%@", v, Q([as.string substringWithRange:r])]];
    }];
    P(@"postal %@ -> %@ runs=[%@]", tag, Q(s), [runs componentsJoinedByString:@" "]);
}

static void PostalGoldens(void) {
    PFmt(@"P1 us", Addr(@"123 Example Street\nApt 4", nil, @"Springfield", nil, @"IL", @"62701", @"United States", @"us"));
    PFmt(@"P1b us no country", Addr(@"123 Example Street", nil, @"Springfield", nil, @"IL", @"62701", nil, @"us"));
    PFmt(@"P1c us sublocality+county", Addr(@"123 Example Street", @"Downtown", @"Springfield", @"Sangamon County", @"IL", @"62701", @"United States", @"us"));
    PFmt(@"P2 de", Addr(@"Beispielstraße 5", nil, @"Berlin", nil, nil, @"10115", @"Germany", @"de"));
    PFmt(@"P3 jp", Addr(@"千代田1-1", nil, @"千代田区", nil, @"東京都", @"100-0001", @"日本", @"jp"));
    PFmt(@"P4 gb", Addr(@"10 Example Road", nil, @"London", nil, nil, @"SW1A 1AA", @"United Kingdom", @"gb"));
    PFmt(@"P5 fr", Addr(@"5 rue Exemple", nil, @"Paris", nil, nil, @"75001", @"France", @"fr"));
    PFmt(@"P6 cn", Addr(@"示例路1号", @"东城区", @"北京市", nil, @"北京市", @"100000", @"中国", @"cn"));
    PFmt(@"P7 ca no iso", Addr(@"1 Example Ave", nil, @"Toronto", nil, @"ON", @"M5V 2T6", @"Canada", nil));
    PFmt(@"P8 nothing but street", Addr(@"1 Example Ave", nil, nil, nil, nil, nil, nil, nil));
    PFmt(@"P9 br", Addr(@"Rua Exemplo, 100", @"Centro", @"São Paulo", nil, @"SP", @"01000-000", @"Brasil", @"br"));
    PFmt(@"P10 au", Addr(@"1 Example St", nil, @"Sydney", nil, @"NSW", @"2000", @"Australia", @"au"));
    PFmt(@"P11 in", Addr(@"1 Example Marg", @"Connaught Place", @"New Delhi", nil, @"Delhi", @"110001", @"India", @"in"));
    PFmt(@"P12 kr", Addr(@"세종대로 1", nil, @"중구", nil, @"서울특별시", @"04524", @"대한민국", @"kr"));
    PFmt(@"P13 iso unknown", Addr(@"1 Example St", nil, @"Exampleville", nil, @"EX", @"00000", @"Exampleland", @"zz"));
    PFmt(@"P14 iso uppercase", Addr(@"Beispielstraße 5", nil, @"Berlin", nil, nil, @"10115", @"Germany", @"DE"));
}

static void VCardOut(NSString *tag, NSArray *contacts) {
    NSError *e = nil;
    NSData *d = [CNContactVCardSerialization dataWithContacts:contacts error:&e];
    if (!d) { P(@"vcard-out %@ err=%@", tag, E(e)); return; }
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    P(@"vcard-out %@ bytes=%lu utf8=%d crlf=%d", tag, (unsigned long)d.length, s != nil, [s containsString:@"\r\n"]);
    NSArray *lines = [s componentsSeparatedByString:@"\r\n"];
    int i = 0;
    for (NSString *l in lines) {
        NSString *x = l.length > 160 ? [[l substringToIndex:160] stringByAppendingFormat:@"…(%lu)", (unsigned long)l.length] : l;
        P(@"vcard-out %@ L%02d %@", tag, ++i, x);
    }
}

static void VCardIn(NSString *tag, NSString *text) {
    NSError *e = nil;
    NSArray *cs = [CNContactVCardSerialization contactsWithData:[text dataUsingEncoding:NSUTF8StringEncoding] error:&e];
    P(@"vcard-in %@ n=%@ err=%@", tag, cs ? @(cs.count) : @"nil", E(e));
    for (CNContact *c in cs) {
        P(@"vcard-in %@ contact id=%@ %@", tag, c.identifier, CDesc(c));
        NSMutableArray *missing = [NSMutableArray array];
        for (NSString *k in AllKeys(YES)) if (![c isKeyAvailable:k]) [missing addObject:k];
        P(@"vcard-in %@ keys not available: [%@]", tag, [missing componentsJoinedByString:@","]);
    }
}

static void VCards(void) {
    P(@"vcard descriptorForRequiredKeys=%@", Strip([(NSObject *)[CNContactVCardSerialization descriptorForRequiredKeys] description]));
    CNMutableContact *f = Full(@"Avery", @"Example");
    VCardOut(@"V1 full", @[ f ]);
    CNMutableContact *n = [f mutableCopy];
    n.note = @"Made-up note, with comma; semicolon\nand newline";
    VCardOut(@"V2 full+note", @[ n ]);
    CNMutableContact *o = [CNMutableContact new];
    o.contactType = CNContactTypeOrganization; o.organizationName = @"Example Widgets LLC";
    o.phoneNumbers = @[ L(CNLabelPhoneNumberMain, Ph(@"555-010-0100")) ];
    VCardOut(@"V3 organization", @[ o ]);
    CNMutableContact *jp = Name(nil, @"太郎", nil, @"山田", nil, nil, nil);
    jp.phoneticGivenName = @"たろう"; jp.phoneticFamilyName = @"やまだ";
    VCardOut(@"V4 two contacts (cjk)", @[ jp, Name(nil, @"Robin", nil, @"Example", nil, nil, nil) ]);
    CNMutableContact *img = Name(nil, @"Pixel", nil, @"Example", nil, nil, nil);
    img.imageData = TinyPNG();
    VCardOut(@"V5 image", @[ img ]);
    CNMutableContact *bd = Name(nil, @"Noyear", nil, @"Example", nil, nil, nil);
    bd.birthday = DCx(0, 2, 29);
    VCardOut(@"V6 birthday without year", @[ bd ]);
    VCardOut(@"V7 empty contact", @[ [CNMutableContact new] ]);
    VCardOut(@"V8 empty array", @[]);
    // Import: our own made-up vCards.
    NSString *v3 = @"BEGIN:VCARD\r\nVERSION:3.0\r\nPRODID:-//Ycode//Probe//EN\r\nN:Example;Casey;Jordan;Mx.;PhD\r\nFN:Mx. Casey Jordan Example PhD\r\n"
                   "NICKNAME:Case\r\nORG:Example Widgets LLC;Research\r\nTITLE:Lead Prober\r\nX-PHONETIC-FIRST-NAME:KAY-see\r\nX-PHONETIC-LAST-NAME:ig-ZAM-pul\r\n"
                   "X-MAIDENNAME:Sample\r\nTEL;type=CELL;type=VOICE;type=pref:+1 555 010 0201\r\nTEL;type=HOME;type=VOICE:555-010-0202\r\nTEL;type=WORK;type=FAX:555-010-0203\r\n"
                   "TEL;type=IPHONE;type=CELL:555-010-0204\r\nTEL;type=MAIN:555-010-0205\r\nTEL;type=PAGER:555-010-0206\r\nitem1.TEL:555-010-0207\r\nitem1.X-ABLabel:Probe line\r\n"
                   "TEL:555-010-0208\r\nEMAIL;type=INTERNET;type=HOME;type=pref:casey@example.com\r\nEMAIL;type=INTERNET;type=WORK:casey@example.org\r\n"
                   "item2.EMAIL;type=INTERNET:casey@example.net\r\nitem2.X-ABLabel:_$!<Other>!$_\r\n"
                   "ADR;type=HOME;type=pref:;;1 Example Way\\nSuite 2;Springfield;IL;62701;United States\r\nitem3.ADR;type=WORK:;Floor 3;5 Example Plaza;Exampleton;CA;90000;USA\r\nitem3.X-ABADR:us\r\n"
                   "URL;type=HOME:https://example.com/casey\r\nitem4.URL:https://example.org/casey\r\nitem4.X-ABLabel:_$!<HomePage>!$_\r\n"
                   "BDAY;value=date:1985-07-04\r\nitem5.X-ABDATE;type=pref:2010-09-01\r\nitem5.X-ABLabel:_$!<Anniversary>!$_\r\n"
                   "item6.X-ABRELATEDNAMES;type=pref:Robin Example\r\nitem6.X-ABLabel:_$!<Spouse>!$_\r\n"
                   "IMPP;X-SERVICE-TYPE=Jabber;type=HOME:xmpp:casey@example.com\r\nX-AIM;type=HOME:caseyaim\r\n"
                   "X-SOCIALPROFILE;type=twitter:https://twitter.com/caseyprobe\r\n"
                   "NOTE:Line one\\nLine two\\, with comma\r\nCATEGORIES:Probe,Test\r\nUID:ycode-probe-uid-1\r\nREV:2026-10-01T00:00:00Z\r\nX-YCODE-UNKNOWN:kept?\r\nEND:VCARD\r\n";
    VCardIn(@"I1 v3 rich", v3);
    NSString *v4 = @"BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Riley Example\r\nN:Example;Riley;;;\r\nKIND:individual\r\nGENDER:F\r\n"
                   "TEL;VALUE=uri;TYPE=\"voice,cell\";PREF=1:tel:+1-555-010-0301\r\nEMAIL;TYPE=work:riley@example.org\r\n"
                   "ADR;TYPE=home;LABEL=\"1 Example Way\\nSpringfield, IL 62701\":;;1 Example Way;Springfield;IL;62701;USA\r\n"
                   "BDAY:--0315\r\nANNIVERSARY:20100901\r\nRELATED;TYPE=spouse;VALUE=text:Robin Example\r\nIMPP;PREF=1:xmpp:riley@example.com\r\n"
                   "LANG:en\r\nURL:https://example.com/riley\r\nEND:VCARD\r\n";
    VCardIn(@"I2 v4", v4);
    NSString *v21 = @"BEGIN:VCARD\r\nVERSION:2.1\r\nN;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:Exampl=C3=A9;Jos=C3=A9;;;\r\nFN;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:Jos=C3=A9 Exampl=C3=A9\r\n"
                    "TEL;CELL:555-010-0401\r\nTEL;WORK;FAX:555-010-0402\r\nEMAIL;INTERNET:jose@example.com\r\nEND:VCARD\r\n";
    VCardIn(@"I3 v2.1 quoted-printable", v21);
    NSString *org = @"BEGIN:VCARD\r\nVERSION:3.0\r\nN:;;;;\r\nFN:Example Widgets LLC\r\nORG:Example Widgets LLC;\r\nX-ABShowAs:COMPANY\r\nTEL;type=MAIN:555-010-0500\r\nEND:VCARD\r\n";
    VCardIn(@"I4 company (X-ABShowAs)", org);
    NSString *two = [NSString stringWithFormat:@"%@%@", @"BEGIN:VCARD\nVERSION:3.0\nN:One;Probe;;;\nFN:Probe One\nEND:VCARD\n",
                     @"BEGIN:VCARD\nVERSION:3.0\nN:Two;Probe;;;\nFN:Probe Two\nEND:VCARD\n"];
    VCardIn(@"I5 two cards LF only", two);
    VCardIn(@"I6 folded line", @"BEGIN:VCARD\r\nVERSION:3.0\r\nN:Folded;Probe;;;\r\nFN:Probe Folded\r\nNOTE:This note is fol\r\n ded across two lines\r\nEND:VCARD\r\n");
    VCardIn(@"I7 fn only", @"BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Only Formatted Name\r\nEND:VCARD\r\n");
    VCardIn(@"I8 malformed (no END)", @"BEGIN:VCARD\r\nVERSION:3.0\r\nN:Broken;Probe;;;\r\n");
    VCardIn(@"I9 garbage", @"this is not a vcard");
    VCardIn(@"I10 empty", @"");
    VCardIn(@"I11 photo", [NSString stringWithFormat:@"BEGIN:VCARD\r\nVERSION:3.0\r\nN:Photo;Probe;;;\r\nPHOTO;ENCODING=b;TYPE=PNG:%@\r\nEND:VCARD\r\n",
                                                   [TinyPNG() base64EncodedStringWithOptions:0]]);
    VCardIn(@"I12 no version", @"BEGIN:VCARD\r\nN:Nover;Probe;;;\r\nEND:VCARD\r\n");
    // Round trip.
    NSData *d = [CNContactVCardSerialization dataWithContacts:@[ f ] error:nil];
    NSArray *back = [CNContactVCardSerialization contactsWithData:d error:nil];
    P(@"vcard roundtrip V1 n=%lu %@", (unsigned long)back.count, back.count ? CDesc(back[0]) : @"");
    P(@"vcard roundtrip source  %@", CDesc(f));
}

static void Exceptions(void) {
    CNMutableContact *c = [CNMutableContact new];
    @try { c.phoneNumbers = (id)@[ L(CNLabelHome, @"not a phone number") ]; P(@"wrong value class accepted (no exception)"); }
    @catch (NSException *ex) { P(@"wrong value class EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { NSString *v = [c valueForKey:CNContactGivenNameKey]; P(@"new contact givenName=%@ available(note)=%d", Q(v), [c isKeyAvailable:CNContactNoteKey]); }
    @catch (NSException *ex) { P(@"EXCEPTION %@", ex.name); }
    P(@"new contact identifier=%@ (format)", c.identifier);
    CNMutableContact *c2 = [CNMutableContact new];
    P(@"two new contacts distinct ids=%d", ![c.identifier isEqualToString:c2.identifier]);
    @try { CNContactFetchRequest *r = [[CNContactFetchRequest alloc] initWithKeysToFetch:@[ @"bogusKey" ]]; P(@"fetch request with bogus key built: %@", r ? @"yes" : @"no"); }
    @catch (NSException *ex) { P(@"bogus key EXCEPTION %@: %@", ex.name, ex.reason); }
}

static void PhaseBasic(void) {
    P(@"status=%ld", (long)[CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts]);
    Constants();
    Labels();
    Formatters();
    PostalGoldens();
    VCards();
    Exceptions();
}

// Store calls before any answer. Note: on the reference, the first store call
// of an undetermined client raises the system prompt and blocks the caller.
static void PhaseNoAccess(void) {
    P(@"noaccess status=%ld", (long)[CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts]);
    P(@"noaccess currentHistoryToken=%@", gStore.currentHistoryToken ? @"data" : @"nil");
    P(@"noaccess defaultContainerIdentifier=%@", [gStore defaultContainerIdentifier]);
    NSError *e = nil;
    NSArray *r = [gStore unifiedContactsMatchingPredicate:[CNContact predicateForContactsMatchingName:@"Example"] keysToFetch:@[ CNContactGivenNameKey ] error:&e];
    P(@"noaccess fetch n=%@ err=%@", r ? @(r.count) : @"nil", E(e));
    e = nil;
    NSArray *ct = [gStore containersMatchingPredicate:nil error:&e];
    P(@"noaccess containers n=%@ err=%@", ct ? @(ct.count) : @"nil", E(e));
    CNSaveRequest *sr = [CNSaveRequest new];
    [sr addContact:Name(nil, @"Noaccess", nil, @"Example", nil, nil, nil) toContainerWithIdentifier:nil];
    e = nil;
    BOOL ok = [gStore executeSaveRequest:sr error:&e];
    P(@"noaccess save ok=%d err=%@", ok, E(e));
    P(@"noaccess status after=%ld", (long)[CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts]);
}

#pragma mark - request

static void PhaseReq(void) {
    P(@"before req status=%ld", (long)[CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts]);
    CFTimeInterval t0 = CACurrentMediaTime();
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    @try {
        [gStore requestAccessForEntityType:CNEntityTypeContacts completionHandler:^(BOOL granted, NSError *e) {
            P(@"req completion granted=%d err=%@ after %.1fs %@", granted, E(e), CACurrentMediaTime() - t0, Thr());
            dispatch_semaphore_signal(s);
        }];
    } @catch (NSException *ex) { P(@"req EXCEPTION %@: %@", ex.name, ex.reason); return; }
    if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 900 * NSEC_PER_SEC))) P(@"req TIMEOUT");
    P(@"after req status=%ld", (long)[CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts]);
}

#pragma mark - data

static NSArray *Fetch(NSString *tag, NSPredicate *p, NSArray *keys) {
    NSError *e = nil;
    NSArray *r = [gStore unifiedContactsMatchingPredicate:p keysToFetch:keys error:&e];
    NSMutableArray *names = [NSMutableArray array];
    for (CNContact *c in r) [names addObject:[NSString stringWithFormat:@"%@ %@%@", c.givenName, c.familyName, [c isKeyAvailable:CNContactOrganizationNameKey] && c.organizationName.length ? [@" @" stringByAppendingString:c.organizationName] : @""]];
    [names sortUsingSelector:@selector(compare:)];
    P(@"fetch %@ n=%@ err=%@ -> [%@]", tag, r ? @(r.count) : @"nil", E(e), [names componentsJoinedByString:@", "]);
    return r;
}

static BOOL Exec(NSString *tag, CNSaveRequest *r) {
    NSError *e = nil;
    BOOL ok = NO;
    @try { ok = [gStore executeSaveRequest:r error:&e]; }
    @catch (NSException *ex) { P(@"save %@ EXCEPTION %@: %@", tag, ex.name, ex.reason); return NO; }
    P(@"save %@ ok=%d err=%@", tag, ok, E(e));
    return ok;
}

static NSArray *ProbeContacts(NSArray *keys) {
    NSError *e = nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *fam in @[ @"Example", @"Sample", @"山田", @"Probe" ]) {
        NSArray *r = [gStore unifiedContactsMatchingPredicate:[CNContact predicateForContactsMatchingName:fam] keysToFetch:keys error:&e];
        for (CNContact *c in r) if ([c.note hasPrefix:@"ycode-probe"] || [c.organizationName hasPrefix:@"Ycode Probe"] || [c.jobTitle isEqualToString:@"ycode-probe"]) {
            BOOL dup = NO;
            for (CNContact *x in out) if ([x.identifier isEqualToString:c.identifier]) dup = YES;
            if (!dup) [out addObject:c];
        }
    }
    return out;
}

static void Wipe(void) {
    NSArray *keys = @[ CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactJobTitleKey ];
    NSError *e = nil;
    NSMutableArray *mine = [NSMutableArray array];
    [gStore enumerateContactsWithFetchRequest:[[CNContactFetchRequest alloc] initWithKeysToFetch:keys] error:&e usingBlock:^(CNContact *c, BOOL *stop) {
        if ([c.jobTitle isEqualToString:@"ycode-probe"] || [c.familyName hasPrefix:@"Probe"] || [c.organizationName hasPrefix:@"Ycode Probe"]) [mine addObject:c];
    }];
    CNSaveRequest *r = [CNSaveRequest new];
    for (CNContact *c in mine) [r deleteContact:[c mutableCopy]];
    NSArray *gs = [gStore groupsMatchingPredicate:nil error:&e];
    for (CNGroup *g in gs) if ([g.name hasPrefix:@"Ycode Probe"]) [r deleteGroup:[g mutableCopy]];
    if (mine.count || gs.count) Exec([NSString stringWithFormat:@"wipe %lu contacts", (unsigned long)mine.count], r);
}

static void PhaseData(BOOL notesEntitled) {
    P(@"data status=%ld notesEntitled=%d", (long)[CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts], notesEntitled);
    __block int changes = 0;
    id obs = [[NSNotificationCenter defaultCenter] addObserverForName:CNContactStoreDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        changes++;
        NSMutableArray *k = [NSMutableArray array];
        for (id key in n.userInfo) [k addObject:[NSString stringWithFormat:@"%@=%@", key, [n.userInfo[key] isKindOfClass:[NSArray class]] ? [NSString stringWithFormat:@"array(%lu)", (unsigned long)[n.userInfo[key] count]] : n.userInfo[key]]];
        P(@"NOTIFY CNContactStoreDidChange #%d object=%@ userInfo={%@} %@", changes, n.object ? NSStringFromClass([n.object class]) : @"nil", [k componentsJoinedByString:@"; "], Thr());
    }];
    NSError *e = nil;
    // Containers.
    NSString *defc = [gStore defaultContainerIdentifier];
    P(@"defaultContainerIdentifier=%@", defc);
    NSArray *conts = [gStore containersMatchingPredicate:nil error:&e];
    P(@"containers n=%@ err=%@", conts ? @(conts.count) : @"nil", E(e));
    for (CNContainer *c in conts) P(@"container id=%@ name=%@ type=%ld", c.identifier, Q(c.name), (long)c.type);
    e = nil;
    NSArray *gs0 = [gStore groupsMatchingPredicate:nil error:&e];
    P(@"groups before n=%@ err=%@", gs0 ? @(gs0.count) : @"nil", E(e));
    Wipe();
    NSData *tok0 = gStore.currentHistoryToken;
    P(@"history token before: %@ (%lu bytes)", tok0 ? @"data" : @"nil", (unsigned long)tok0.length);
    // All visible contacts (seed data).
    __block int visible = 0;
    e = nil;
    BOOL en = [gStore enumerateContactsWithFetchRequest:[[CNContactFetchRequest alloc] initWithKeysToFetch:@[ CNContactGivenNameKey, CNContactFamilyNameKey ]] error:&e
                                           usingBlock:^(CNContact *c, BOOL *stop) { visible++; }];
    P(@"visible contacts before=%d ok=%d err=%@", visible, en, E(e));

    // Create.
    CNMutableContact *c1 = Full(@"Avery", @"Example"); c1.jobTitle = @"ycode-probe";
    if (notesEntitled) c1.note = @"ycode-probe note";
    CNMutableContact *c2 = Name(nil, @"Blake", nil, @"Example", nil, nil, nil); c2.jobTitle = @"ycode-probe";
    c2.phoneNumbers = @[ L(CNLabelPhoneNumberMobile, Ph(@"(555) 010-0601")) ]; c2.emailAddresses = @[ L(CNLabelWork, @"blake@example.org") ];
    CNMutableContact *c3 = Name(nil, @"Casey", nil, @"Sample", nil, nil, nil); c3.jobTitle = @"ycode-probe";
    c3.phoneNumbers = @[ L(CNLabelHome, Ph(@"+1 555 010 0602")) ];
    CNMutableContact *c4 = Name(nil, @"太郎", nil, @"山田", nil, nil, nil); c4.jobTitle = @"ycode-probe";
    c4.phoneticGivenName = @"たろう"; c4.phoneticFamilyName = @"やまだ";
    CNMutableContact *c5 = Name(nil, nil, nil, nil, nil, nil, @"Ycode Probe Widgets"); c5.contactType = CNContactTypeOrganization; c5.jobTitle = @"ycode-probe";
    CNMutableContact *c6 = Name(nil, @"Avery", nil, @"Example", nil, nil, nil); c6.jobTitle = @"ycode-probe"; // same name as c1
    c6.emailAddresses = @[ L(CNLabelHome, @"avery@example.com") ];
    CNMutableContact *c7 = Name(nil, @"Pixel", nil, @"Probe", nil, nil, nil); c7.jobTitle = @"ycode-probe"; c7.imageData = TinyPNG();
    CNSaveRequest *sr = [CNSaveRequest new];
    sr.transactionAuthor = @"dev.ycode.cnprobe.author";
    for (CNMutableContact *c in @[ c1, c2, c3, c4, c5, c6, c7 ]) [sr addContact:c toContainerWithIdentifier:nil];
    P(@"before save c1.identifier=%@", c1.identifier);
    Exec(@"add 7", sr);
    P(@"after save c1.identifier=%@ shouldRefetch default=%d", c1.identifier, sr.shouldRefetchContacts);
    Sleep(2);
    P(@"notifications after add: %d", changes);
    // Fetch with all keys (notes only when entitled).
    e = nil;
    CNContact *f1 = [gStore unifiedContactWithIdentifier:c1.identifier keysToFetch:AllKeys(NO) error:&e];
    P(@"c1 refetch err=%@ %@", E(e), f1 ? CDesc(f1) : @"nil");
    P(@"c1 refetch identifier same=%d", [f1.identifier isEqualToString:c1.identifier]);
    e = nil;
    CNContact *f1n = [gStore unifiedContactWithIdentifier:c1.identifier keysToFetch:@[ CNContactNoteKey, CNContactGivenNameKey ] error:&e];
    P(@"c1 fetch with note key err=%@ note=%@", E(e), f1n ? Q(f1n.note) : @"(no contact)");
    e = nil;
    CNContact *f7 = [gStore unifiedContactWithIdentifier:c7.identifier keysToFetch:@[ CNContactImageDataKey, CNContactThumbnailImageDataKey, CNContactImageDataAvailableKey ] error:&e];
    P(@"c7 image err=%@ image=%lu thumb=%lu available=%d", E(e), (unsigned long)f7.imageData.length, (unsigned long)f7.thumbnailImageData.length, f7.imageDataAvailable);
    // Partial keys.
    CNContact *part = [gStore unifiedContactWithIdentifier:c1.identifier keysToFetch:@[ CNContactGivenNameKey ] error:nil];
    P(@"partial available(given)=%d available(family)=%d areKeysAvailable(formatter)=%d", [part isKeyAvailable:CNContactGivenNameKey],
      [part isKeyAvailable:CNContactFamilyNameKey], [part areKeysAvailable:@[ [CNContactFormatter descriptorForRequiredKeysForStyle:CNContactFormatterStyleFullName] ]]);
    @try { P(@"partial familyName=%@", part.familyName); } @catch (NSException *ex) { P(@"partial familyName EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { P(@"partial formatter=%@", [CNContactFormatter stringFromContact:part style:CNContactFormatterStyleFullName]); }
    @catch (NSException *ex) { P(@"partial formatter EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { [CNContactVCardSerialization dataWithContacts:@[ part ] error:nil]; P(@"partial vcard: no exception"); }
    @catch (NSException *ex) { P(@"partial vcard EXCEPTION %@: %@", ex.name, ex.reason); }
    CNContact *viaDesc = [gStore unifiedContactWithIdentifier:c1.identifier keysToFetch:@[ [CNContactFormatter descriptorForRequiredKeysForStyle:CNContactFormatterStyleFullName] ] error:nil];
    P(@"descriptor fetch formatted=%@", Q([CNContactFormatter stringFromContact:viaDesc style:CNContactFormatterStyleFullName]));
    // Predicates.
    NSArray *k = @[ CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey ];
    Fetch(@"name 'Example'", [CNContact predicateForContactsMatchingName:@"Example"], k);
    Fetch(@"name 'exam'", [CNContact predicateForContactsMatchingName:@"exam"], k);
    Fetch(@"name 'xample'", [CNContact predicateForContactsMatchingName:@"xample"], k);
    Fetch(@"name 'avery example'", [CNContact predicateForContactsMatchingName:@"avery example"], k);
    Fetch(@"name 'Example Avery'", [CNContact predicateForContactsMatchingName:@"Example Avery"], k);
    Fetch(@"name 'Ave' (nickname)", [CNContact predicateForContactsMatchingName:@"Ave"], k);
    Fetch(@"name 'Ycode Probe Widgets' (org)", [CNContact predicateForContactsMatchingName:@"Ycode Probe Widgets"], k);
    Fetch(@"name 'Widgets'", [CNContact predicateForContactsMatchingName:@"Widgets"], k);
    Fetch(@"name '山田'", [CNContact predicateForContactsMatchingName:@"山田"], k);
    Fetch(@"name 'やまだ' (phonetic)", [CNContact predicateForContactsMatchingName:@"やまだ"], k);
    Fetch(@"name 'Jose' vs accents", [CNContact predicateForContactsMatchingName:@"Avéry"], k);
    Fetch(@"email exact", [CNContact predicateForContactsMatchingEmailAddress:@"avery@example.com"], k);
    Fetch(@"email case", [CNContact predicateForContactsMatchingEmailAddress:@"AVERY@EXAMPLE.COM"], k);
    Fetch(@"email partial", [CNContact predicateForContactsMatchingEmailAddress:@"avery@example"], k);
    Fetch(@"phone '5550100601'", [CNContact predicateForContactsMatchingPhoneNumber:Ph(@"5550100601")], k);
    Fetch(@"phone '+1 555-010-0601'", [CNContact predicateForContactsMatchingPhoneNumber:Ph(@"+1 555-010-0601")], k);
    Fetch(@"phone '0100601' (suffix)", [CNContact predicateForContactsMatchingPhoneNumber:Ph(@"0100601")], k);
    Fetch(@"phone '555 010 0602' (stored with +1)", [CNContact predicateForContactsMatchingPhoneNumber:Ph(@"555 010 0602")], k);
    Fetch(@"phone '+44 20 7946 0000'", [CNContact predicateForContactsMatchingPhoneNumber:Ph(@"+44 20 7946 0000")], k);
    Fetch(@"identifiers c2,c3,bogus", [CNContact predicateForContactsWithIdentifiers:@[ c2.identifier, c3.identifier, @"bogus" ]], k);
    Fetch(@"in container default", [CNContact predicateForContactsInContainerWithIdentifier:defc], k);
    @try { Fetch(@"nspredicate (unsupported)", [NSPredicate predicateWithFormat:@"givenName == 'Avery'"], k); }
    @catch (NSException *ex) { P(@"nspredicate EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { Fetch(@"nil predicate", nil, k); } @catch (NSException *ex) { P(@"nil predicate EXCEPTION %@: %@", ex.name, ex.reason); }
    // Enumerate with sort orders.
    for (NSNumber *so in @[ @(CNContactSortOrderGivenName), @(CNContactSortOrderFamilyName), @(CNContactSortOrderNone), @(CNContactSortOrderUserDefault) ]) {
        CNContactFetchRequest *fr = [[CNContactFetchRequest alloc] initWithKeysToFetch:@[ CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactJobTitleKey ]];
        fr.sortOrder = so.integerValue;
        NSMutableArray *names = [NSMutableArray array];
        e = nil;
        [gStore enumerateContactsWithFetchRequest:fr error:&e usingBlock:^(CNContact *c, BOOL *stop) {
            if ([c.jobTitle isEqualToString:@"ycode-probe"]) [names addObject:[NSString stringWithFormat:@"%@/%@/%@", c.givenName, c.familyName, c.organizationName]];
        }];
        P(@"enumerate sortOrder=%@ err=%@ -> %@", so, E(e), [names componentsJoinedByString:@", "]);
    }
    CNContactFetchRequest *fu = [[CNContactFetchRequest alloc] initWithKeysToFetch:@[ CNContactGivenNameKey ]];
    fu.unifyResults = NO; fu.predicate = [CNContact predicateForContactsMatchingName:@"Example"];
    __block int nu = 0; [gStore enumerateContactsWithFetchRequest:fu error:nil usingBlock:^(CNContact *c, BOOL *stop) { nu++; }];
    fu.unifyResults = YES; __block int yu = 0; [gStore enumerateContactsWithFetchRequest:fu error:nil usingBlock:^(CNContact *c, BOOL *stop) { yu++; }];
    P(@"unifyResults NO=%d YES=%d (Example)", nu, yu);
    P(@"c1 isUnifiedWith c6=%d c1 isUnifiedWith c1=%d", [f1 isUnifiedWithContactWithIdentifier:c6.identifier], [f1 isUnifiedWithContactWithIdentifier:c1.identifier]);
    fu.mutableObjects = YES;
    __block NSString *cls = nil;
    [gStore enumerateContactsWithFetchRequest:fu error:nil usingBlock:^(CNContact *c, BOOL *stop) { cls = NSStringFromClass([c class]); *stop = YES; }];
    P(@"mutableObjects=YES class=%@", cls);
    e = nil;
    CNFetchResult *fres = [gStore enumeratorForContactFetchRequest:fu error:&e];
    P(@"enumeratorForContactFetchRequest value=%@ token=%@ err=%@", NSStringFromClass([fres.value class]), fres.currentHistoryToken ? @"data" : @"nil", E(e));

    // Groups.
    CNMutableGroup *g = [CNMutableGroup new]; g.name = @"Ycode Probe Group";
    CNMutableGroup *g2 = [CNMutableGroup new]; g2.name = @"Ycode Probe Group 2";
    sr = [CNSaveRequest new];
    [sr addGroup:g toContainerWithIdentifier:nil];
    [sr addGroup:g2 toContainerWithIdentifier:nil];
    [sr addMember:c2 toGroup:g]; [sr addMember:c3 toGroup:g];
    Exec(@"add groups+members", sr);
    P(@"group identifier=%@", g.identifier);
    Fetch(@"in group", [CNContact predicateForContactsInGroupWithIdentifier:g.identifier], k);
    e = nil;
    NSArray *gs = [gStore groupsMatchingPredicate:[CNGroup predicateForGroupsInContainerWithIdentifier:defc] error:&e];
    for (CNGroup *x in gs) P(@"group in default container: %@ id=%@", Q(x.name), x.identifier);
    e = nil;
    NSArray *gc = [gStore containersMatchingPredicate:[CNContainer predicateForContainerOfGroupWithIdentifier:g.identifier] error:&e];
    P(@"container of group n=%lu err=%@ same-as-default=%d", (unsigned long)gc.count, E(e), [[gc.firstObject identifier] isEqualToString:defc]);
    gc = [gStore containersMatchingPredicate:[CNContainer predicateForContainerOfContactWithIdentifier:c1.identifier] error:&e];
    P(@"container of contact n=%lu same-as-default=%d", (unsigned long)gc.count, [[gc.firstObject identifier] isEqualToString:defc]);
    sr = [CNSaveRequest new]; [sr addMember:c2 toGroup:g];
    Exec(@"err add member twice", sr);
    sr = [CNSaveRequest new]; [sr removeMember:c4 fromGroup:g];
    Exec(@"err remove non-member", sr);
    CNMutableGroup *gx = [g mutableCopy]; gx.name = @"Ycode Probe Group renamed";
    sr = [CNSaveRequest new]; [sr updateGroup:gx]; Exec(@"rename group", sr);
    sr = [CNSaveRequest new]; [sr addGroup:[g mutableCopy] toContainerWithIdentifier:nil]; Exec(@"err add existing group again", sr);
    sr = [CNSaveRequest new]; [sr addContact:[c2 mutableCopy] toContainerWithIdentifier:nil]; Exec(@"err add existing contact again", sr);
    sr = [CNSaveRequest new]; [sr addContact:Name(nil, @"Bogus", nil, @"Probe", nil, nil, nil) toContainerWithIdentifier:@"bogus-container"]; Exec(@"err bogus container", sr);
    // Update.
    CNMutableContact *u = [[gStore unifiedContactWithIdentifier:c2.identifier keysToFetch:AllKeys(NO) error:nil] mutableCopy];
    u.givenName = @"Blair";
    u.phoneNumbers = [u.phoneNumbers arrayByAddingObject:L(CNLabelWork, Ph(@"555-010-0699"))];
    NSString *lvid = [u.phoneNumbers.firstObject identifier];
    sr = [CNSaveRequest new]; [sr updateContact:u]; Exec(@"update c2", sr);
    CNContact *u2 = [gStore unifiedContactWithIdentifier:c2.identifier keysToFetch:@[ CNContactGivenNameKey, CNContactPhoneNumbersKey ] error:nil];
    P(@"c2 after update given=%@ phones=%@ first labeled value id stable=%d", u2.givenName, LV(u2.phoneNumbers), [[u2.phoneNumbers.firstObject identifier] isEqualToString:lvid]);
    CNMutableContact *partial = [[gStore unifiedContactWithIdentifier:c3.identifier keysToFetch:@[ CNContactGivenNameKey ] error:nil] mutableCopy];
    partial.givenName = @"Cassidy";
    sr = [CNSaveRequest new]; [sr updateContact:partial]; Exec(@"update partially fetched c3", sr);
    CNContact *p3 = [gStore unifiedContactWithIdentifier:c3.identifier keysToFetch:@[ CNContactGivenNameKey, CNContactPhoneNumbersKey ] error:nil];
    P(@"c3 after partial update given=%@ phones kept=%@", p3.givenName, LV(p3.phoneNumbers));
    @try { partial.familyName = @"Changed"; P(@"setting unfetched key on mutable partial: accepted"); }
    @catch (NSException *ex) { P(@"setting unfetched key EXCEPTION %@: %@", ex.name, ex.reason); }
    if (!notesEntitled) {
        CNMutableContact *nn = [[gStore unifiedContactWithIdentifier:c3.identifier keysToFetch:@[ CNContactGivenNameKey ] error:nil] mutableCopy];
        @try { nn.note = @"ycode-probe unentitled"; sr = [CNSaveRequest new]; [sr updateContact:nn]; Exec(@"update note without entitlement", sr); }
        @catch (NSException *ex) { P(@"note without entitlement EXCEPTION %@: %@", ex.name, ex.reason); }
        CNMutableContact *nn2 = Name(nil, @"Noted", nil, @"Probe", nil, nil, nil); nn2.jobTitle = @"ycode-probe"; nn2.note = @"ycode-probe new with note";
        sr = [CNSaveRequest new]; [sr addContact:nn2 toContainerWithIdentifier:nil]; Exec(@"add contact with note without entitlement", sr);
    }
    // Delete.
    sr = [CNSaveRequest new]; [sr deleteContact:[c6 mutableCopy]]; Exec(@"delete c6", sr);
    sr = [CNSaveRequest new]; [sr deleteContact:[c6 mutableCopy]]; Exec(@"err delete c6 again", sr);
    sr = [CNSaveRequest new]; [sr updateContact:[c6 mutableCopy]]; Exec(@"err update deleted c6", sr);
    e = nil;
    CNContact *gone = [gStore unifiedContactWithIdentifier:c6.identifier keysToFetch:@[ CNContactGivenNameKey ] error:&e];
    P(@"fetch deleted c6 -> %@ err=%@", gone ? @"object" : @"nil", E(e));
    e = nil;
    gone = [gStore unifiedContactWithIdentifier:@"bogus" keysToFetch:@[ CNContactGivenNameKey ] error:&e];
    P(@"fetch bogus id -> %@ err=%@", gone ? @"object" : @"nil", E(e));
    // Multiple operations in one request, one failing.
    sr = [CNSaveRequest new];
    CNMutableContact *ok1 = Name(nil, @"Atomic", nil, @"Probe", nil, nil, nil); ok1.jobTitle = @"ycode-probe";
    [sr addContact:ok1 toContainerWithIdentifier:nil];
    [sr deleteContact:[c6 mutableCopy]];
    Exec(@"atomic (add ok + delete missing)", sr);
    Fetch(@"after atomic", [CNContact predicateForContactsMatchingName:@"Atomic"], k);
    Sleep(2);
    // Change history.
    if (tok0) {
        CNChangeHistoryFetchRequest *hr = [CNChangeHistoryFetchRequest new];
        hr.startingToken = tok0;
        hr.additionalContactKeyDescriptors = @[ CNContactGivenNameKey, CNContactFamilyNameKey ];
        hr.shouldUnifyResults = YES;
        e = nil;
        CNFetchResult *res = [gStore enumeratorForChangeHistoryFetchRequest:hr error:&e];
        P(@"history fetch err=%@ token=%@", E(e), res.currentHistoryToken ? @"data" : @"nil");
        NSMutableDictionary *counts = [NSMutableDictionary dictionary];
        for (CNChangeHistoryEvent *ev in res.value) {
            NSString *cn = NSStringFromClass([ev class]);
            counts[cn] = @([counts[cn] intValue] + 1);
        }
        P(@"history events by class: %@", [[counts description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
        hr.excludedTransactionAuthors = @[ @"dev.ycode.cnprobe.author" ];
        res = [gStore enumeratorForChangeHistoryFetchRequest:hr error:&e];
        int n2 = 0; for (id ev in res.value) { (void)ev; n2++; }
        P(@"history excluding our author: %d events", n2);
        hr.startingToken = nil;
        res = [gStore enumeratorForChangeHistoryFetchRequest:hr error:&e];
        counts = [NSMutableDictionary dictionary];
        for (CNChangeHistoryEvent *ev in res.value) { NSString *cn = NSStringFromClass([ev class]); counts[cn] = @([counts[cn] intValue] + 1); }
        P(@"history from nil token: %@ err=%@", [[counts description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "], E(e));
        hr.startingToken = [@"bogus" dataUsingEncoding:NSUTF8StringEncoding];
        e = nil;
        res = [gStore enumeratorForChangeHistoryFetchRequest:hr error:&e];
        n2 = 0; for (id ev in res.value) { (void)ev; n2++; }
        P(@"history bogus token: events=%d err=%@", n2, E(e));
    }
    P(@"history token after differs=%d", ![gStore.currentHistoryToken isEqualToData:tok0]);
    P(@"total notifications: %d", changes);
    [[NSNotificationCenter defaultCenter] removeObserver:obs];
}

static void PhaseList(void) {
    P(@"list status=%ld", (long)[CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts]);
    NSError *e = nil;
    NSMutableArray *rows = [NSMutableArray array];
    CNContactFetchRequest *fr = [[CNContactFetchRequest alloc] initWithKeysToFetch:@[ CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                                                                                       CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactImageDataAvailableKey ]];
    fr.sortOrder = CNContactSortOrderFamilyName;
    BOOL ok = [gStore enumerateContactsWithFetchRequest:fr error:&e usingBlock:^(CNContact *c, BOOL *stop) {
        [rows addObject:[NSString stringWithFormat:@"%@|%@|%@|phones=%lu|emails=%lu|image=%d|id=%@", c.givenName, c.familyName, c.organizationName,
                         (unsigned long)c.phoneNumbers.count, (unsigned long)c.emailAddresses.count, c.imageDataAvailable, c.identifier]];
    }];
    P(@"list ok=%d err=%@ n=%lu", ok, E(e), (unsigned long)rows.count);
    for (NSString *r in rows) P(@"list %@", r);
    NSArray *gs = [gStore groupsMatchingPredicate:nil error:&e];
    for (CNGroup *g in gs) P(@"list group %@ id=%@", Q(g.name), g.identifier);
    NSArray *cs = [gStore containersMatchingPredicate:nil error:&e];
    for (CNContainer *c in cs) P(@"list container %@ type=%ld id=%@", Q(c.name), (long)c.type, c.identifier);
}

static void PhaseCount(void) {
    NSArray *mine = ProbeContacts(@[ CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactJobTitleKey ]);
    P(@"count status=%ld probe contacts=%lu", (long)[CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts], (unsigned long)mine.count);
}

#pragma mark - UI

@interface UIDel : NSObject <CNContactPickerDelegate, CNContactViewControllerDelegate>
@end
@implementation UIDel
- (void)contactPickerDidCancel:(CNContactPickerViewController *)p { P(@"UI picker cancel %@", Thr()); }
- (void)contactPicker:(CNContactPickerViewController *)p didSelectContact:(CNContact *)c {
    P(@"UI picker selected class=%@ id=%@ %@", NSStringFromClass([c class]), c.identifier, CDesc(c));
}
- (void)contactViewController:(CNContactViewController *)vc didCompleteWithContact:(CNContact *)c {
    P(@"UI contactVC complete contact=%@", c ? CDesc(c) : @"nil");
    [vc dismissViewControllerAnimated:YES completion:nil];
}
@end
static UIDel *gDel;

static void PhaseUI(NSString *phase) {
    P(@"%@ status=%ld", phase, (long)[CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts]);
    gDel = [UIDel new];
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *vc = nil;
            if ([phase isEqualToString:@"uipicker"]) {
                CNContactPickerViewController *p = [CNContactPickerViewController new];
                p.delegate = gDel;
                vc = p;
            } else if ([phase isEqualToString:@"uinew"]) {
                CNMutableContact *c = Name(nil, @"Prefilled", nil, @"Probe", nil, nil, nil);
                CNContactViewController *v = [CNContactViewController viewControllerForNewContact:c];
                v.delegate = gDel;
                vc = [[UINavigationController alloc] initWithRootViewController:v];
            } else {
                CNMutableContact *c = Name(nil, @"Unknown", nil, @"Probe", nil, nil, nil);
                c.phoneNumbers = @[ L(CNLabelPhoneNumberMobile, Ph(@"555-010-0999")) ];
                CNContactViewController *v = [CNContactViewController viewControllerForUnknownContact:c];
                v.delegate = gDel; v.contactStore = gStore; v.allowsActions = YES;
                vc = [[UINavigationController alloc] initWithRootViewController:v];
            }
            [gRoot presentViewController:vc animated:YES completion:^{ P(@"UI presented %@", NSStringFromClass([vc class])); }];
        } @catch (NSException *ex) { P(@"UI EXCEPTION %@: %@", ex.name, ex.reason); }
    });
    [NSThread sleepForTimeInterval:8];
    P(@"UI presentedViewController=%@", NSStringFromClass([gRoot.presentedViewController class]));
}

#pragma mark - App

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor systemGreenColor];
    UILabel *l = [UILabel new]; l.text = @"CNProbe"; l.frame = CGRectMake(40, 120, 300, 40); [vc.view addSubview:l];
    self.window.rootViewController = vc;
    gRoot = vc;
    [self.window makeKeyAndVisible];
    P(@"scene connected");
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    NSString *phase = [[NSUserDefaults standardUserDefaults] stringForKey:@"phase"] ?: @"basic";
    BOOL notes = [[NSBundle mainBundle].bundleIdentifier hasSuffix:@".notes"];
    P(@"launch phase=%@ bundle=%@ tz=%@ locale=%@ region=%@", phase, [NSBundle mainBundle].bundleIdentifier, [NSTimeZone systemTimeZone].name,
      [NSLocale currentLocale].localeIdentifier, [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode]);
    dispatch_queue_t q = dispatch_queue_create("dev.ycode.cnprobe.runner", DISPATCH_QUEUE_SERIAL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), q, ^{
        @try {
            gStore = [CNContactStore new];
            if ([phase isEqualToString:@"basic"]) PhaseBasic();
            else if ([phase isEqualToString:@"req"]) PhaseReq();
            else if ([phase isEqualToString:@"noaccess"]) PhaseNoAccess();
            else if ([phase isEqualToString:@"status"]) P(@"status=%ld", (long)[CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts]);
            else if ([phase isEqualToString:@"data"]) PhaseData(notes);
            else if ([phase isEqualToString:@"list"]) PhaseList();
            else if ([phase isEqualToString:@"count"]) PhaseCount();
            else if ([phase isEqualToString:@"wipe"]) Wipe();
            else if ([phase hasPrefix:@"ui"]) PhaseUI(phase);
        } @catch (NSException *ex) { P(@"PHASE EXCEPTION %@: %@", ex.name, ex.reason); }
        P(@"phase %@ DONE", phase);
    });
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = [SceneDelegate class];
    return c;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        gStart = CACurrentMediaTime();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
