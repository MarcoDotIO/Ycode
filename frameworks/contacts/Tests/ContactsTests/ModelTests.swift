// C-CN-MODEL (plan.md §3): constants, enumerations, labels, keys and their
// availability, identifiers, labeled values and the two exceptions.

import Foundation
import Testing
@testable import Contacts

@Suite("C-CN-MODEL identifiers.md: constants and enumerations")
struct ConstantTests {
    @Test("identifiers.md string constants: every value of the table")
    func stringConstants() throws {
        // The spec's table, read at test time: name → value.
        #expect(ycodeAllStringConstants.count == 309)
        let byName = Dictionary(uniqueKeysWithValues: ycodeAllStringConstants.map { ($0.name, $0.value) })
        #expect(byName["CNContactPostalAddressesKey"] == "postalAddresses")
        #expect(byName["CNContactRelationsKey"] == "contactRelations")
        #expect(byName["CNContactPropertyAttribute"] == "contactProperty")
        #expect(byName["CNContactStoreDidChangeNotification"] == "CNContactStoreDidChangeNotification")
        #expect(byName["CNErrorUserInfoAffectedRecordsKey"] == "CNInvalidRecords")
        #expect(byName["CNErrorUserInfoAffectedRecordIdentifiersKey"] == "CNInvalidRecordIdentifiers")
        #expect(byName["CNErrorUserInfoKeyPathsKey"] == "CNKeyPaths")
        #expect(byName["CNErrorUserInfoValidationErrorsKey"] == "CNValidationErrors")
        #expect(byName["CNContactPropertyNotFetchedExceptionName"] == "CNPropertyNotFetchedException")
        #expect(byName["CNPostalAddressPropertyAttribute"] == "postalAddressProperty")
        #expect(byName["CNPostalAddressLocalizedPropertyNameAttribute"] == "postalAddressLocalizedPropertyName")
        #expect(byName["CNSocialProfileServiceGameCenter"] == "Game Center")
        #expect(byName["CNLabelPhoneNumberAppleWatch"] == "Apple Watch")
    }

    @Test("interface.md §2.1: each key equals its property name except the three exceptions")
    func keyStrings() {
        #expect(CNContactGivenNameKey == "givenName")
        #expect(CNContactUrlAddressesKey == "urlAddresses")
        #expect(CNContactTypeKey == "contactType")
        #expect(CNContactPostalAddressesKey == "postalAddresses")
        #expect(CNContactRelationsKey == "contactRelations")
        #expect(CNContactPropertyAttribute == "contactProperty")
        #expect(CNContainerTypeKey == "type")
        #expect(CNGroupNameKey == "name")
        #expect(Notification.Name.CNContactStoreDidChange.rawValue == "CNContactStoreDidChangeNotification")
    }

    @Test("identifiers.md: labels")
    func labels() {
        #expect(CNLabelHome == "_$!<Home>!$_")
        #expect(CNLabelWork == "_$!<Work>!$_")
        #expect(CNLabelSchool == "_$!<School>!$_")
        #expect(CNLabelOther == "_$!<Other>!$_")
        #expect(CNLabelEmailiCloud == "iCloud")
        #expect(CNLabelPhoneNumberiPhone == "iPhone")
        #expect(CNLabelPhoneNumberHomeFax == "_$!<HomeFAX>!$_")
        #expect(CNLabelURLAddressHomePage == "_$!<HomePage>!$_")
        #expect(CNLabelDateAnniversary == "_$!<Anniversary>!$_")
        #expect(CNLabelContactRelationSpouse == "_$!<Spouse>!$_")
        #expect(CNLabelContactRelationGranddaughterOrNiece == "_$!<GranddaughterOrNiece>!$_")
        #expect(ycodeAllLabelConstants.count == 231)
    }

    @Test("identifiers.md: enumeration raw values")
    func enums() {
        #expect([CNAuthorizationStatus.notDetermined, .restricted, .denied, .authorized, .limited].map(\.rawValue) == [0, 1, 2, 3, 4])
        #expect([CNContactDisplayNameOrder.userDefault, .givenNameFirst, .familyNameFirst].map(\.rawValue) == [0, 1, 2])
        #expect([CNContactFormatterStyle.fullName, .phoneticFullName].map(\.rawValue) == [0, 1])
        #expect([CNContactSortOrder.none, .userDefault, .givenName, .familyName].map(\.rawValue) == [0, 1, 2, 3])
        #expect([CNContactType.person, .organization].map(\.rawValue) == [0, 1])
        #expect([CNContainerType.unassigned, .local, .exchange, .cardDAV].map(\.rawValue) == [0, 1, 2, 3])
        #expect(CNEntityType.contacts.rawValue == 0)
        #expect(CNPostalAddressFormatterStyle.mailingAddress.rawValue == 0)
    }

    @Test("errors.md §1: error domain and codes")
    func errorCodes() {
        #expect(CNErrorDomain == "CNErrorDomain")
        let codes: [(CNError.Code, Int)] = [
            (.communicationError, 1), (.dataAccessError, 2), (.authorizationDenied, 100),
            (.noAccessableWritableContainers, 101), (.unauthorizedKeys, 102), (.featureDisabledByUser, 103),
            (.featureNotAvailable, 104), (.recordDoesNotExist, 200), (.insertedRecordAlreadyExists, 201),
            (.containmentCycle, 202), (.containmentScope, 203), (.parentRecordDoesNotExist, 204),
            (.recordIdentifierInvalid, 205), (.recordNotWritable, 206), (.parentContainerNotWritable, 207),
            (.validationMultipleErrors, 300), (.validationTypeMismatch, 301), (.validationConfigurationError, 302),
            (.predicateInvalid, 400), (.policyViolation, 500), (.clientIdentifierInvalid, 600),
            (.clientIdentifierDoesNotExist, 601), (.clientIdentifierCollision, 602), (.changeHistoryExpired, 603),
            (.changeHistoryInvalidAnchor, 604), (.changeHistoryInvalidFetchRequest, 605), (.vCardMalformed, 700),
            (.vCardSummarizationError, 701),
        ]
        for (code, value) in codes { #expect(code.rawValue == value) }
        let e = CNError(.recordDoesNotExist, userInfo: [CNErrorUserInfoKeyPathsKey: ["note"]]) as NSError
        #expect(e.domain == CNErrorDomain)
        #expect(e.code == 200)
        #expect((e.userInfo[CNErrorUserInfoKeyPathsKey] as? [String]) == ["note"])
    }
}

@Suite("C-CN-MODEL interface.md §2.4: label and key localization")
struct LocalizationTests {
    @Test("predefined labels localize to lower-case English words, custom labels unchanged")
    func labelWords() {
        let expected: [(String, String)] = [
            (CNLabelHome, "home"), (CNLabelWork, "work"), (CNLabelSchool, "school"), (CNLabelOther, "other"),
            (CNLabelURLAddressHomePage, "homepage"), (CNLabelDateAnniversary, "anniversary"),
            (CNLabelPhoneNumberMobile, "mobile"), (CNLabelPhoneNumberMain, "main"), (CNLabelPhoneNumberHomeFax, "home fax"),
            (CNLabelPhoneNumberWorkFax, "work fax"), (CNLabelPhoneNumberOtherFax, "other fax"), (CNLabelPhoneNumberPager, "pager"),
            (CNLabelPhoneNumberiPhone, "iPhone"), (CNLabelEmailiCloud, "iCloud"), (CNLabelPhoneNumberAppleWatch, "Apple Watch"),
            (CNLabelContactRelationFather, "father"), (CNLabelContactRelationMother, "mother"),
            (CNLabelContactRelationSpouse, "spouse"), ("Gym locker", "Gym locker"),
        ]
        for (label, word) in expected {
            #expect(CNLabeledValue<NSString>.localizedString(forLabel: label) == word)
        }
        // Ycode's rule for relation labels the spec does not list.
        #expect(CNLabeledValue<NSString>.localizedString(forLabel: CNLabelContactRelationSisterInLawBrothersWife) == "sister-in-law")
        #expect(CNLabeledValue<NSString>.localizedString(forLabel: CNLabelContactRelationElderBrother) == "older brother")
        #expect(CNLabeledValue<NSString>.localizedString(forLabel: CNLabelContactRelationParentsSibling) == "parent's sibling")
    }

    @Test("localizedStringForKey: field names; none for identifier, thumbnail and availability")
    func keyNames() {
        #expect(CNContact.localizedString(forKey: CNContactGivenNameKey) == "First name")
        #expect(CNContact.localizedString(forKey: CNContactFamilyNameKey) == "Last name")
        #expect(CNContact.localizedString(forKey: CNContactPreviousFamilyNameKey) == "Maiden name")
        #expect(CNContact.localizedString(forKey: CNContactOrganizationNameKey) == "Company")
        #expect(CNContact.localizedString(forKey: CNContactJobTitleKey) == "Job title")
        #expect(CNContact.localizedString(forKey: CNContactNonGregorianBirthdayKey) == "Alternate calendar birthday")
        #expect(CNContact.localizedString(forKey: CNContactRelationsKey) == "Related name")
        #expect(CNContact.localizedString(forKey: CNContactSocialProfilesKey) == "Social profile")
        #expect(CNContact.localizedString(forKey: CNContactInstantMessageAddressesKey) == "Instant message")
        for k in [CNContactIdentifierKey, CNContactThumbnailImageDataKey, CNContactImageDataAvailableKey] {
            #expect(CNContact.localizedString(forKey: k) == "")
        }
        let postal: [(String, String)] = [
            (CNPostalAddressStreetKey, "Street"), (CNPostalAddressSubLocalityKey, "District"), (CNPostalAddressCityKey, "City"),
            (CNPostalAddressSubAdministrativeAreaKey, "County"), (CNPostalAddressStateKey, "State"),
            (CNPostalAddressPostalCodeKey, "ZIP"), (CNPostalAddressCountryKey, "Country"),
            (CNPostalAddressISOCountryCodeKey, "Country code"),
        ]
        for (k, v) in postal { #expect(CNPostalAddress.localizedString(forKey: k) == v) }
        #expect(CNSocialProfile.localizedString(forService: CNSocialProfileServiceTwitter) == "Twitter")
        #expect(CNInstantMessageAddress.localizedString(forService: CNInstantMessageServiceJabber) == "Jabber")
    }

    @Test("interface.md §1: CNContactsUserDefaults sort order 3, country code us")
    func userDefaults() {
        #expect(CNContactsUserDefaults.shared().sortOrder == .familyName)
        #expect(CNContactsUserDefaults.shared().countryCode == "us")
    }
}

@Suite("C-CN-MODEL interface.md §2.2–§2.3: contacts, keys and identifiers")
struct ContactModelTests {
    @Test("§2.3: new contacts get <UUID>:ABPerson; the Identifiable id is the UUID")
    func newIdentifier() throws {
        let c = CNMutableContact()
        let parts = c.identifier.split(separator: ":")
        #expect(parts.count == 2)
        #expect(parts[1] == "ABPerson")
        #expect(UUID(uuidString: String(parts[0])) != nil)
        #expect(c.id.uuidString == String(parts[0]))
        #expect(CNContact().identifier.hasSuffix(":ABPerson"))
        #expect(CNMutableContact().identifier != c.identifier)
        #expect(CNMutableGroup().identifier.hasSuffix(":ABGroup"))
    }

    @Test("§2.3: the labeled-value identifier is kept when the label or value changes, but the object differs")
    func labeledValueIdentifier() {
        let lv = phone("(555) 010-0100", CNLabelHome)
        #expect(UUID(uuidString: lv.identifier) != nil)
        let relabeled = lv.settingLabel(CNLabelWork)
        #expect(relabeled.identifier == lv.identifier)
        #expect(relabeled.label == CNLabelWork)
        #expect(!relabeled.isEqual(lv))
        #expect(lv.settingValue(CNPhoneNumber(stringValue: "1")).identifier == lv.identifier)
        #expect(lv.settingLabel(nil, value: CNPhoneNumber(stringValue: "2")).identifier == lv.identifier)
        #expect(lv.isEqual(lv.copy()))
        #expect(phone("(555) 010-0100", CNLabelHome).identifier != lv.identifier)
    }

    @Test("§2.2: a new contact has every key but the note (no notes entitlement)")
    func newContactKeys() {
        let c = CNMutableContact()
        #expect(c.isKeyAvailable(CNContactGivenNameKey))
        #expect(c.areKeysAvailable([CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]))
        #expect(!c.isKeyAvailable(CNContactNoteKey))
        let e = raised { c.note = "Bring the blue folder." }
        #expect(e?.name == "CNPropertyNotFetchedException")
        #expect(e?.reason == "A property was not requested when contact was fetched.")
        YcodeContactsEnvironment.$notesOverride.withValue(true) {
            let n = CNMutableContact()
            n.note = "Bring the blue folder."
            #expect(n.note == "Bring the blue folder.")
        }
    }

    @Test("§2.2: reading and setting an unfetched property raises CNPropertyNotFetchedException")
    func unfetched() {
        let partial = CNContact(identifier: "p:ABPerson", data: ContactData(), available: [CNContactGivenNameKey])
        #expect(raised { partial.givenName } == nil)
        #expect(raised { partial.identifier } == nil)
        let e = raised { partial.familyName }
        #expect(e == CNException(name: CNContactPropertyNotFetchedExceptionName,
                                 reason: "A property was not requested when contact was fetched."))
        #expect(raised { partial.phoneNumbers } != nil)
        #expect(!partial.isKeyAvailable(CNContactFamilyNameKey))
        #expect(partial.isKeyAvailable(CNContactIdentifierKey))
        let m = partial.mutableCopy() as! CNMutableContact
        m.givenName = "Avery"
        #expect(m.givenName == "Avery")
        #expect(raised { m.familyName = "Example" } != nil)
        #expect(raised { CNContactFormatter.string(from: partial, style: .fullName) } != nil)
    }

    @Test("§2.2: a raise outside CNException.catching stops the process")
    func raiseTerminates() async {
        await #expect(processExitsWith: .failure) {
            let partial = CNContact(identifier: "p:ABPerson", data: ContactData(), available: [])
            _ = partial.givenName
        }
    }

    @Test("§2.4: a value of the wrong class raises CNPropertyInvalidTypeException naming the expected class")
    func invalidType() {
        let c = CNMutableContact()
        let wrong = CNLabeledValue<NSString>(label: CNLabelHome, value: ns("not a phone"))
        let e = raised { c.setValue([wrong], forKey: CNContactPhoneNumbersKey) }
        #expect(e?.name == "CNPropertyInvalidTypeException")
        let reason = e?.reason ?? ""
        #expect(reason.hasPrefix("Labeled value "))
        #expect(reason.contains(" value not a phone has incorrect type NSString."))
        #expect(reason.hasSuffix("It should be CNPhoneNumber."))
        #expect(c.phoneNumbers.isEmpty)
        c.setValue([phone("(555) 010-0100")], forKey: CNContactPhoneNumbersKey)
        #expect(c.phoneNumbers.count == 1)
        c.setValue("Avery", forKey: CNContactGivenNameKey)
        #expect(c.value(forKey: CNContactGivenNameKey) as? String == "Avery")
    }

    @Test("copies: immutable and mutable, values copied into labeled values")
    func copies() {
        let m = person("Avery", "Example")
        let addr = CNMutablePostalAddress()
        addr.street = "1 Example Ave"
        m.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: addr)]
        addr.street = "changed"
        #expect(m.postalAddresses[0].value.street == "1 Example Ave")
        #expect(!(m.postalAddresses[0].value is CNMutablePostalAddress))
        let frozen = m.copy() as! CNContact
        #expect(!(frozen is CNMutableContact))
        #expect(frozen.givenName == "Avery")
        #expect(frozen.isEqual(m.copy()))
        let again = frozen.mutableCopy() as! CNMutableContact
        again.givenName = "Blake"
        #expect(frozen.givenName == "Avery")
        #expect(again.identifier == frozen.identifier)
        #expect((frozen.copy() as AnyObject) === frozen)
    }

    @Test("§4.4: isUnifiedWithContactWithIdentifier is NO even for the contact's own identifier")
    func unified() {
        let c = CNMutableContact()
        #expect(!c.isUnifiedWithContact(withIdentifier: c.identifier))
    }

    @Test("key descriptors describe themselves as CNAggregateKeyDescriptor with a kind")
    func descriptors() {
        let d = CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        let text = String(describing: d)
        #expect(text.hasPrefix("<CNAggregateKeyDescriptor: 0x"))
        #expect(text.contains(": kind="))
        #expect(d._cnKeys.contains(CNContactGivenNameKey))
        #expect(CNContactVCardSerialization.descriptorForRequiredKeys()._cnKeys.contains(CNContactPhoneNumbersKey))
        #expect(!CNContactVCardSerialization.descriptorForRequiredKeys()._cnKeys.contains(CNContactNoteKey))
        #expect(CNContact.descriptorForAllComparatorKeys()._cnKeys.contains(CNContactFamilyNameKey))
        #expect(ns(CNContactGivenNameKey)._cnKeys == [CNContactGivenNameKey])
    }
}
