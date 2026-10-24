# Contacts spec: errors and exceptions

Part of `specs/frameworks/contacts/`. Code names and values are from the SDK
(level 4; table in `identifiers.md`); the situations, user-info keys and
messages were observed with `CNProbe` on iOS 27.1 (level 3).

## 1. Domain, codes and user-info keys

Domain `CNErrorDomain`. Codes: 1 communication error, 2 data access error,
100 authorization denied, 101 no accessible writable containers, 102
unauthorized keys, 103 feature disabled by user, 104 feature not available,
200 record does not exist, 201 inserted record already exists, 202
containment cycle, 203 containment scope, 204 parent record does not exist,
205 record identifier invalid, 206 record not writable, 207 parent container
not writable, 300 validation multiple errors, 301 validation type mismatch,
302 validation configuration error, 400 predicate invalid, 500 policy
violation, 600 client identifier invalid, 601 client identifier does not
exist, 602 client identifier collision, 603 change history expired, 604
change history invalid anchor, 605 change history invalid fetch request,
700 vCard malformed, 701 vCard summarization error.

User-info keys (string values in `identifiers.md`):
`CNErrorUserInfoAffectedRecordsKey` = "CNInvalidRecords",
`CNErrorUserInfoAffectedRecordIdentifiersKey` = "CNInvalidRecordIdentifiers",
`CNErrorUserInfoKeyPathsKey` = "CNKeyPaths",
`CNErrorUserInfoValidationErrorsKey` = "CNValidationErrors", plus
`NSLocalizedDescription` and `NSLocalizedFailureReason`.

## 2. Observed errors

| Situation | Code | Description | Keys |
|---|---|---|---|
| fetch with the note key without the notes entitlement | 102 | "Unauthorized Keys" | `CNInvalidRecords`, `CNKeyPaths` (["note"]), description, failure reason |
| fetch a deleted or unknown identifier | 200 | "Updated Record Does Not Exist" | description, failure reason |
| update / member change of a record that does not exist; add members to a group added in the same request | 200 | "Updated Record Does Not Exist" | `CNInvalidRecords`, description, failure reason |
| add to an unknown container | 200 | "Updated Record Does Not Exist" | `CNInvalidRecordIdentifiers` (1 identifier), description, failure reason |
| add a contact that is already saved | 201 | "Duplicate Record" | `CNInvalidRecords`, description, failure reason |
| store calls by an app **without** the usage string | — | the app is terminated by the privacy system (§4) | — |

Not errors (observed): deleting an already deleted contact; a request that
adds a contact and deletes a missing one; a bogus history token (empty
result with full access); malformed or empty vCard data (0 contacts, nil
error); fetching with an `NSPredicate` that is not a Contacts predicate.

Messages are Apple's localized resources; Ycode writes its own English text
with the same meaning. Codes and user-info keys are the contract.

## 3. Exceptions

| Name (string value) | When (observed) | Reason text |
|---|---|---|
| `CNPropertyNotFetchedException` (`CNContactPropertyNotFetchedExceptionName`) | reading or setting a property whose key was not fetched; formatting a contact without the formatter's keys; setting `note` without the notes entitlement | "A property was not requested when contact was fetched." |
| `CNPropertyInvalidTypeException` | a labeled value of the wrong class in a multi-valued property | "Labeled value <description> value <value> has incorrect type <class>. It should be <expected class>." |

## 4. Missing usage string

An app without `NSContactsUsageDescription` that calls
`requestAccessForEntityType:completion:` or any store data call is
terminated by the system (level 1; see `authorization.md` §3 for the
observation).

## Evidence

| Claim | Level |
|---|---|
| Domain, code names and values, key names | 4 |
| Key string values | 3 |
| Situations, descriptions, user-info keys | 3 |
| Non-errors | 3 |
| Exceptions and reasons | 3 |
| Termination without usage string | 1 + 3 (`authorization.md`) |
