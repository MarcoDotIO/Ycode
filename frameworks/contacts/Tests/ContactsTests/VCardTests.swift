// C-CN-FORMAT formats.md §3: vCard export (§3.1 line mapping) and import
// (§3.2, I1–I12). All cards and contacts are made up.

import Foundation
import Testing
@testable import Contacts

/// A contact that exercises every exported property.
func richContact() -> CNMutableContact {
    let c = CNMutableContact()
    c.namePrefix = "Dr."; c.givenName = "Avery"; c.middleName = "Quinn"; c.familyName = "Example"; c.nameSuffix = "Jr."
    c.nickname = "Ave"
    c.previousFamilyName = "Sample"
    c.phoneticGivenName = "AY-ver-ee"
    c.phoneticFamilyName = "ig-ZAM-pul"
    c.organizationName = "Example Widgets LLC"
    c.departmentName = "Research"
    c.jobTitle = "Engineer"
    c.emailAddresses = [email("avery@example.com", CNLabelHome), email("avery@widgets.example", CNLabelWork),
                        email("avery@icloud.example", CNLabelEmailiCloud)]
    c.phoneNumbers = [phone("(555) 010-0101", CNLabelPhoneNumberMobile), phone("(555) 010-0102", CNLabelPhoneNumberiPhone),
                      phone("(555) 010-0103", CNLabelPhoneNumberHomeFax), phone("555-010-0104", nil)]
    let a = CNMutablePostalAddress()
    a.street = "1 Example Ave\nApt 2"; a.city = "Springfield"; a.state = "IL"; a.postalCode = "62701"
    a.country = "United States"; a.isoCountryCode = "us"
    c.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: a)]
    c.socialProfiles = [CNLabeledValue(label: nil, value: CNSocialProfile(urlString: "https://twitter.example/avery",
                                                                          username: "avery", userIdentifier: nil,
                                                                          service: CNSocialProfileServiceTwitter))]
    c.urlAddresses = [CNLabeledValue(label: CNLabelURLAddressHomePage, value: ns("https://example.com/avery")),
                      CNLabeledValue(label: CNLabelWork, value: ns("https://widgets.example"))]
    c.birthday = gregorian(1990, 3, 15)
    var hebrew = DateComponents()
    hebrew.calendar = Calendar(identifier: .hebrew)
    hebrew.year = 5750; hebrew.month = 7; hebrew.day = 18
    c.nonGregorianBirthday = hebrew
    c.instantMessageAddresses = [
        CNLabeledValue(label: CNLabelHome, value: CNInstantMessageAddress(username: "avery.aim", service: CNInstantMessageServiceAIM)),
        CNLabeledValue(label: CNLabelWork, value: CNInstantMessageAddress(username: "avery@jabber.example", service: CNInstantMessageServiceJabber)),
        CNLabeledValue(label: CNLabelOther, value: CNInstantMessageAddress(username: "avery.chat", service: "Ycode Chat")),
    ]
    c.dates = [CNLabeledValue(label: CNLabelDateAnniversary, value: nsDateComponents(gregorian(2015, 6, 20))),
               CNLabeledValue(label: "Graduation", value: nsDateComponents(gregorian(nil, 5, 30)))]
    c.contactRelations = [CNLabeledValue(label: CNLabelContactRelationSpouse, value: CNContactRelation(name: "Blake Example"))]
    return c
}

let richLines = [
    "BEGIN:VCARD",
    "VERSION:3.0",
    "PRODID:-//Ycode//Ycode Contacts 1.0//EN",
    "N:Example;Avery;Quinn;Dr.;Jr.",
    "FN:Dr. Avery Quinn Example Jr.",
    "NICKNAME:Ave",
    "X-MAIDENNAME:Sample",
    "X-PHONETIC-FIRST-NAME:AY-ver-ee",
    "X-PHONETIC-LAST-NAME:ig-ZAM-pul",
    "ORG:Example Widgets LLC;Research",
    "TITLE:Engineer",
    "EMAIL;type=INTERNET;type=HOME;type=pref:avery@example.com",
    "EMAIL;type=INTERNET;type=WORK:avery@widgets.example",
    "item1.EMAIL;type=INTERNET:avery@icloud.example",
    "item1.X-ABLabel:iCloud",
    "TEL;type=CELL;type=VOICE;type=pref:(555) 010-0101",
    "TEL;type=IPHONE;type=CELL;type=VOICE:(555) 010-0102",
    "TEL;type=HOME;type=FAX:(555) 010-0103",
    "TEL:555-010-0104",
    "item2.ADR;type=HOME;type=pref:;;1 Example Ave\\nApt 2;Springfield;IL;62701;United States",
    "item2.X-ABADR:us",
    "X-SOCIALPROFILE;type=twitter;x-user=avery:https://twitter.example/avery",
    "item3.URL;type=pref:https://example.com/avery",
    "item3.X-ABLabel:_$!<HomePage>!$_",
    "URL;type=WORK:https://widgets.example",
    "BDAY:1990-03-15",
    "X-ALTBDAY;CALSCALE=hebrew:-57500718",
    "X-AIM;type=HOME;type=pref:avery.aim",
    "IMPP;X-SERVICE-TYPE=AIM;type=HOME;type=pref:aim:avery.aim",
    "X-JABBER;type=WORK:avery@jabber.example",
    "IMPP;X-SERVICE-TYPE=Jabber;type=WORK:xmpp:avery@jabber.example",
    "item4.IMPP;X-SERVICE-TYPE=Ycode Chat:x-apple:avery.chat",
    "item4.X-ABLabel:_$!<Other>!$_",
    "item5.X-ABDATE;type=pref:2015-06-20",
    "item5.X-ABLabel:_$!<Anniversary>!$_",
    "item6.X-ABDATE;X-APPLE-OMIT-YEAR=1604:1604-05-30",
    "item6.X-ABLabel:Graduation",
    "item7.X-ABRELATEDNAMES;type=pref:Blake Example",
    "item7.X-ABLabel:_$!<Spouse>!$_",
    "END:VCARD",
]

@Suite("C-CN-FORMAT formats.md §3.1: vCard export")
struct VCardExportTests {
    @Test("§3.1: every property of a rich contact, in the line order of the mapping table (byte-exact)")
    func rich() throws {
        let data = try CNContactVCardSerialization.data(with: [richContact()])
        #expect(vcardLines(data) == richLines)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("END:VCARD\r\n"))
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test("§3.1: empty contact writes N:;;;; and no FN")
    func empty() throws {
        let lines = vcardLines(try CNContactVCardSerialization.data(with: [CNMutableContact()]))
        #expect(lines == ["BEGIN:VCARD", "VERSION:3.0", "PRODID:-//Ycode//Ycode Contacts 1.0//EN", "N:;;;;", "END:VCARD"])
    }

    @Test("§3.1: organization contact: ORG with empty department, X-ABShowAs:COMPANY")
    func organization() throws {
        let c = CNMutableContact()
        c.contactType = .organization
        c.organizationName = "Example Widgets LLC"
        let lines = vcardLines(try CNContactVCardSerialization.data(with: [c]))
        #expect(lines == ["BEGIN:VCARD", "VERSION:3.0", "PRODID:-//Ycode//Ycode Contacts 1.0//EN", "N:;;;;",
                          "FN:Example Widgets LLC", "ORG:Example Widgets LLC;", "X-ABShowAs:COMPANY", "END:VCARD"])
    }

    @Test("§3.1: birthday without year; structured values escape ; and ,; note and image are not exported")
    func birthdayEscapesAndOmissions() throws {
        try YcodeContactsEnvironment.$notesOverride.withValue(true) {
            let c = person("Avery", "Example; Sample", org: "Widgets, Inc.")
            c.birthday = gregorian(nil, 2, 29)
            c.note = "Not written"
            c.imageData = Data(repeating: 7, count: 32)
            let lines = vcardLines(try CNContactVCardSerialization.data(with: [c]))
            #expect(lines == ["BEGIN:VCARD", "VERSION:3.0", "PRODID:-//Ycode//Ycode Contacts 1.0//EN",
                              "N:Example\\; Sample;Avery;;;", "FN:Avery Example; Sample", "ORG:Widgets\\, Inc.;",
                              "BDAY;X-APPLE-OMIT-YEAR=1604:1604-02-29", "END:VCARD"])
        }
    }

    @Test("§3: several contacts give consecutive cards; an empty array gives empty data")
    func several() throws {
        let data = try CNContactVCardSerialization.data(with: [person("Avery", "Example"), person("Blake", "Example")])
        let lines = vcardLines(data)
        #expect(lines.filter { $0 == "BEGIN:VCARD" }.count == 2)
        #expect(lines.filter { $0 == "END:VCARD" }.count == 2)
        #expect(try CNContactVCardSerialization.data(with: []).isEmpty)
    }

    @Test("interface.md §2.2: export of a partially fetched contact does not raise; it fails")
    func partial() {
        let partial = CNContact(identifier: "p:ABPerson", data: ContactData(), available: [CNContactGivenNameKey])
        #expect(raised { (try? CNContactVCardSerialization.data(with: [partial])) as Data? } == nil)
        #expect(throws: (any Error).self) { try CNContactVCardSerialization.data(with: [partial]) }
    }
}

@Suite("C-CN-FORMAT formats.md §3.2: vCard import")
struct VCardImportTests {
    @Test("round trip of the rich contact: equal except social label and the Gregorian calendar")
    func roundTrip() throws {
        let original = richContact()
        let back = try CNContactVCardSerialization.contacts(with: try CNContactVCardSerialization.data(with: [original]))
        #expect(back.count == 1)
        let c = back[0]
        #expect(c.identifier != original.identifier)
        #expect(c.identifier.hasSuffix(":ABPerson"))
        for k in [CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey,
                  CNContactNameSuffixKey, CNContactNicknameKey, CNContactPreviousFamilyNameKey, CNContactPhoneticGivenNameKey,
                  CNContactPhoneticFamilyNameKey, CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey] {
            #expect(c.value(forKey: k) as? String == original.value(forKey: k) as? String, "\(k)")
        }
        #expect(c.emailAddresses.map { String(describing: $0.value) } == original.emailAddresses.map { String(describing: $0.value) })
        #expect(c.emailAddresses.map(\.label) == original.emailAddresses.map(\.label))
        #expect(c.phoneNumbers.map(\.value) == original.phoneNumbers.map(\.value))
        #expect(c.phoneNumbers.map(\.label) == [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone, CNLabelPhoneNumberHomeFax, ""])
        #expect(c.postalAddresses.map(\.value) == original.postalAddresses.map(\.value))
        #expect(c.postalAddresses.first?.label == CNLabelHome)
        #expect(c.urlAddresses.map(\.label) == original.urlAddresses.map(\.label))
        #expect(c.socialProfiles.first?.value.service == "twitter")
        #expect(c.socialProfiles.first?.value.urlString == "https://twitter.example/avery")
        #expect(c.socialProfiles.first?.value.username == "avery")
        #expect(c.socialProfiles.first?.label == "")
        #expect(c.birthday == gregorian(1990, 3, 15))
        #expect(c.nonGregorianBirthday?.calendar?.identifier == .hebrew)
        #expect([c.nonGregorianBirthday?.year, c.nonGregorianBirthday?.month, c.nonGregorianBirthday?.day] == [5750, 7, 18])
        #expect(c.instantMessageAddresses.map(\.value) == original.instantMessageAddresses.map(\.value))
        #expect(c.instantMessageAddresses.map(\.label) == original.instantMessageAddresses.map(\.label))
        #expect(c.dates.map { dateComponents($0.value) } == [gregorian(2015, 6, 20), gregorian(nil, 5, 30)])
        #expect(c.dates.map(\.label) == original.dates.map(\.label))
        #expect(c.contactRelations.map(\.value) == original.contactRelations.map(\.value))
        #expect(c.contactRelations.map(\.label) == original.contactRelations.map(\.label))
        // Imported contacts have every key, note included.
        #expect(c.isKeyAvailable(CNContactNoteKey))
        #expect(raised { c.note } == nil)
    }

    @Test("I1: rich 3.0 card with categories, UID, REV, an unknown X- line, escaped note, unlabeled TEL, extended address")
    func i1() throws {
        let data = vcard([
            "BEGIN:VCARD", "VERSION:3.0", "PRODID:-//Example Corp//Made Up 1.0//EN",
            "N:Example;Avery;;;", "FN:Avery Example", "ORG:Example Widgets LLC;",
            "EMAIL;type=INTERNET;type=WORK;type=pref:avery@widgets.example",
            "TEL:555-010-0201",
            "TEL;type=HOME;type=VOICE:555-010-0202",
            "item3.ADR;type=WORK:;Suite 300;10 Example Plaza;Springfield;IL;62701;United States",
            "item3.X-ABADR:us",
            "X-AIM;type=HOME:avery.aim",
            "X-SOCIALPROFILE;type=twitter:https://twitter.example/avery",
            "NOTE:Line one\\nLine two\\, with comma",
            "CATEGORIES:Probe,Example", "UID:00000000-1111-2222-3333-444444444444", "REV:2026-10-20T10:00:00Z",
            "X-YCODE-UNKNOWN:ignored",
            "END:VCARD",
        ])
        let cs = try CNContactVCardSerialization.contacts(with: data)
        #expect(cs.count == 1)
        let c = cs[0]
        #expect(c.givenName == "Avery")
        #expect(c.organizationName == "Example Widgets LLC")
        #expect(c.note == "Line one\nLine two, with comma")
        #expect(c.emailAddresses.first?.label == CNLabelWork)
        #expect(c.phoneNumbers.map(\.label) == ["", CNLabelHome])
        #expect(c.postalAddresses.first?.value.street == "10 Example Plaza\nSuite 300")
        #expect(c.postalAddresses.first?.value.isoCountryCode == "us")
        #expect(c.postalAddresses.first?.label == CNLabelWork)
        #expect(c.instantMessageAddresses.map(\.value) == [CNInstantMessageAddress(username: "avery.aim", service: "AIM")])
        #expect(c.socialProfiles.first?.value.urlString == "https://twitter.example/avery")
        #expect(c.socialProfiles.first?.value.service == "twitter")
    }

    @Test("I2: vCard 4.0 read leniently as 3.0")
    func i2() throws {
        let data = vcard([
            "BEGIN:VCARD", "VERSION:4.0", "KIND:individual", "FN:Casey Sample", "N:Sample;Casey;;;", "GENDER:F", "LANG:en",
            "TEL;VALUE=uri;TYPE=\"voice,cell\";PREF=1:tel:+1-555-010-0301",
            "EMAIL:casey@example.com",
            "ADR;TYPE=home;LABEL=\"5 Example Rd, Springfield\":;;5 Example Rd;Springfield;IL;62701;USA",
            "BDAY:--0315", "ANNIVERSARY:20100601", "RELATED;TYPE=spouse:urn:uuid:00000000-0000-0000-0000-000000000001",
            "END:VCARD",
        ])
        let c = try CNContactVCardSerialization.contacts(with: data)[0]
        #expect(c.phoneNumbers.first?.label == "VALUE")
        #expect(c.phoneNumbers.first?.value.stringValue == "tel:+1-555-010-0301")
        #expect(c.postalAddresses.first?.label == "LABEL")
        #expect((c.emailAddresses.first?.label ?? "") == "")
        #expect(c.birthday?.month == 3)
        #expect(c.birthday?.day == 15)
        #expect(c.birthday?.year == nil)
        #expect(c.dates.isEmpty)
        #expect(c.contactRelations.isEmpty)
    }

    @Test("I3: vCard 2.1 quoted-printable UTF-8; bare CELL and WORK;FAX types")
    func i3() throws {
        let data = vcard([
            "BEGIN:VCARD", "VERSION:2.1",
            "N;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:Exampl=C3=A9;Jos=C3=A9;;;",
            "FN;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:Jos=C3=A9 Exampl=C3=A9",
            "TEL;CELL:555-010-0401", "TEL;WORK;FAX:555-010-0402", "END:VCARD",
        ])
        let c = try CNContactVCardSerialization.contacts(with: data)[0]
        #expect(formatted(c) == "José Examplé")
        #expect(c.phoneNumbers.map(\.label) == [CNLabelPhoneNumberMobile, CNLabelPhoneNumberWorkFax])
    }

    @Test("I4: X-ABShowAs:COMPANY gives an organization")
    func i4() throws {
        let c = try CNContactVCardSerialization.contacts(with: vcard([
            "BEGIN:VCARD", "VERSION:3.0", "N:;;;;", "FN:Example Widgets LLC", "ORG:Example Widgets LLC;",
            "X-ABShowAs:COMPANY", "END:VCARD",
        ]))[0]
        #expect(c.contactType == .organization)
        #expect(c.givenName == "")
    }

    @Test("I5: two cards with LF line ends")
    func i5() throws {
        let data = vcard(["BEGIN:VCARD", "VERSION:3.0", "N:Example;Avery;;;", "END:VCARD",
                          "BEGIN:VCARD", "VERSION:3.0", "N:Example;Blake;;;", "END:VCARD"], ending: "\n")
        let cs = try CNContactVCardSerialization.contacts(with: data)
        #expect(cs.map(\.givenName) == ["Avery", "Blake"])
    }

    @Test("I6: a folded line is unfolded")
    func i6() throws {
        let c = try CNContactVCardSerialization.contacts(with: vcard([
            "BEGIN:VCARD", "VERSION:3.0", "N:Example;Avery;;;", "NOTE:This note is folded acro", " ss two lines", "END:VCARD",
        ]))[0]
        #expect(c.note == "This note is folded across two lines")
    }

    @Test("I7: FN only: name parts from FN")
    func i7() throws {
        let c = try CNContactVCardSerialization.contacts(with: vcard([
            "BEGIN:VCARD", "VERSION:3.0", "FN:Only Formatted Name", "END:VCARD",
        ]))[0]
        #expect([c.givenName, c.middleName, c.familyName] == ["Only", "Formatted", "Name"])
    }

    @Test("I8–I10: missing END, garbage, empty data: no contacts, no error")
    func unreadable() throws {
        #expect(try CNContactVCardSerialization.contacts(with: Data("BEGIN:VCARD\r\nVERSION:3.0\r\nN:Example;Avery;;;\r\n".utf8)).isEmpty)
        #expect(try CNContactVCardSerialization.contacts(with: Data("this is not a vCard at all\n".utf8)).isEmpty)
        #expect(try CNContactVCardSerialization.contacts(with: Data()).isEmpty)
    }

    @Test("I11: PHOTO in base64 restores the image data; image available")
    func i11() throws {
        var bytes = [UInt8](repeating: 0, count: 324)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        let image = Data(bytes)
        let c = try CNContactVCardSerialization.contacts(with: vcard([
            "BEGIN:VCARD", "VERSION:3.0", "N:Example;Avery;;;", "PHOTO;ENCODING=b;TYPE=PNG:" + image.base64EncodedString(), "END:VCARD",
        ]))[0]
        #expect(c.imageData?.count == 324)
        #expect(c.imageData == image)
        #expect(c.thumbnailImageData == nil)
        #expect(c.imageDataAvailable)
    }

    @Test("I12: a card without VERSION is read")
    func i12() throws {
        let c = try CNContactVCardSerialization.contacts(with: vcard(["BEGIN:VCARD", "N:Example;Avery;;;", "END:VCARD"]))
        #expect(c.first?.givenName == "Avery")
    }
}
