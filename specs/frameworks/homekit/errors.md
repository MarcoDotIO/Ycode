# HomeKit spec: errors

Part of `specs/frameworks/homekit/`. HomeKit reports failures as `NSError`
in domain `HMErrorDomain` (the string equals the constant name) through
completion handlers and `home:didEncounterError:forAccessory:`. HomeKit
does not throw Objective-C exceptions for ordinary misuse that we observed
(level 3: setters and constructors with odd inputs, such as a number range
with min greater than max, did not throw).

## 1. Public codes (`HMErrorCode`)

Names after the `HMErrorCode` prefix (level 4). Codes 1–82 exist since
iOS 8/9; later introductions are marked. Our one-phrase meaning is level 1
(public documentation, summarized) unless the name says it all.

| Code | Name | Meaning / when |
|---|---|---|
| −1 | UnexpectedError (iOS 11.2) | Catch-all |
| 1 | AlreadyExists | Object already exists |
| 2 | NotFound | Object or accessory not found |
| 3 | InvalidParameter | Bad argument (also used internally when a setup URL does not parse, level 3) |
| 4 | AccessoryNotReachable | |
| 5 | ReadOnlyCharacteristic | Write to a read-only characteristic |
| 6 | WriteOnlyCharacteristic | Read of a write-only characteristic |
| 7 | NotificationNotSupported | Characteristic cannot notify |
| 8 | OperationTimedOut | |
| 9 | AccessoryPoweredOff | |
| 10 | AccessDenied | |
| 11–13 | ObjectAssociatedToAnotherHome, ObjectNotAssociatedToAnyHome, ObjectAlreadyAssociatedToHome | Object/home membership errors |
| 14–16 | AccessoryIsBusy, OperationInProgress, AccessoryOutOfResources | Retry later |
| 17 | InsufficientPrivileges | Non-admin user tried an admin-only change |
| 18 | AccessoryPairingFailed | |
| 19–22 | InvalidDataFormatSpecified, NilParameter, UnconfiguredParameter, InvalidClass | Argument errors |
| 23 | OperationCancelled | User or system cancelled (setup UI dismissed; level 3) |
| 24 | RoomForHomeCannotBeInZone | Default room added to a zone |
| 25 | NoActionsInActionSet | Executing an empty action set |
| 26 | NoRegisteredActionSets | Trigger without action sets |
| 27 | MissingParameter | |
| 28 | FireDateInPast | |
| 29 | RoomForHomeCannotBeUpdated | Renaming/removing the default room |
| 30 | ActionInAnotherActionSet | |
| 31–33 | ObjectWithSimilarNameExistsInHome, HomeWithSimilarNameExists, RenameWithSimilarName | Name collisions |
| 34 | CannotRemoveNonBridgeAccessory | Removing a bridged accessory on its own |
| 35, 36, 60 | NameContainsProhibitedCharacters, NameDoesNotStartWithValidCharacters, NameDoesNotEndWithValidCharacters | Name validation |
| 37–41 | UserIDNotEmailAddress, UserDeclinedAddingUser, UserDeclinedRemovingUser, UserDeclinedInvite, UserManagementFailed | Sharing |
| 42, 72 | RecurrenceTooSmall, RecurrenceTooLarge | Timer recurrence limits |
| 43 | InvalidValueType | Wrong value type for the characteristic format |
| 44, 45 | ValueLowerThanMinimum, ValueHigherThanMaximum | Metadata bounds |
| 46, 51 | StringLongerThanMaximum, StringShorterThanMinimum | |
| 47 | HomeAccessNotAuthorized | App not authorized (level 3: after Don't Allow, and without the entitlement) |
| 48 | OperationNotSupported | |
| 49 | MaximumObjectLimitReached | |
| 50, 59 | AccessorySentInvalidResponse, AccessoryResponseError | Accessory-side protocol errors |
| 52 | GenericError | |
| 53–56 | SecurityFailure, CommunicationFailure, MessageAuthenticationFailed, InvalidMessageSize | Transport/session errors |
| 57 | AccessoryDiscoveryFailed | |
| 58 | ClientRequestError | |
| 61 | AccessoryIsBlocked | |
| 62 | InvalidAssociatedServiceType | |
| 63–65 | ActionSetExecutionFailed, ActionSetExecutionPartialSuccess, ActionSetExecutionInProgress | |
| 66 | AccessoryOutOfCompliance | |
| 67 | DataResetFailure | |
| 68 | NotificationAlreadyEnabled | |
| 69, 70 | RecurrenceMustBeOnSpecifiedBoundaries, DateMustBeOnSpecifiedBoundaries | |
| 71 | CannotActivateTriggerTooFarInFuture | |
| 73, 74 | ReadWritePartialSuccess, ReadWriteFailure | Multi-characteristic operations |
| 75–77 | NotSignedIntoiCloud, KeychainSyncNotEnabled, CloudDataSyncInProgress | Account/sync state (note: the simulator returns 2040, not 75; §2) |
| 78 | NetworkUnavailable | |
| 79 | AddAccessoryFailed | |
| 80 | MissingEntitlement | (not observed: a missing entitlement gave 47 or silence; §2) |
| 81 | CannotUnblockNonBridgeAccessory | |
| 82 | DeviceLocked | |
| 83 | CannotRemoveBuiltinActionSet (iOS 9) | |
| 84, 85 | LocationForHomeDisabled, NotAuthorizedForLocationServices (iOS 9) | Location events |
| 86 | ReferToUserManual (iOS 9.3) | |
| 87 | InvalidOrMissingAuthorizationData (iOS 10) | |
| 88 | BridgedAccessoryNotReachable (iOS 10) | |
| 89 | NotAuthorizedForMicrophoneAccess (iOS 10) | Camera two-way audio |
| 90 | IncompatibleNetwork (iOS 10.2) | |
| 91, 92 | NoHomeHub, NoCompatibleHomeHub (iOS 11) | `IncompatibleHomeHub` is a deprecated alias of 92 |
| 93 | IncompatibleAccessory (iOS 11.3) | |
| 95 | ObjectWithSimilarNameExists (iOS 12) | (94 is unused) |
| 96–98 | OwnershipFailure, MaximumAccessoriesOfTypeInHome, WiFiCredentialGenerationFailed (iOS 13) | |
| 99–102 | EnterpriseNetworkNotSupported, TimedOutWaitingForAccessory, AccessoryCommunicationFailure, FailedToJoinNetwork (iOS 14) | |
| 103 | AccessoryIsSuspended (iOS 15) | |
| 104 | PartialCommunicationFailure (iOS 17.4) | |
| 105 | HomeUpgradeRequired (iOS 18.4) | Home not on the current home architecture |

## 2. Observed errors (level 3) — Ycode must reproduce these exactly

| Situation | Domain / code | userInfo |
|---|---|---|
| `addHomeWithName:` with no iCloud account (any name, checked before name validation) | `HMErrorDomain` **2040** (not public) | only `NSLocalizedDescription`, text reads like "unknown error code 2040" |
| `addHomeWithName:` after Don't Allow, or without the entitlement | `HMErrorDomain` 47 | only `NSLocalizedDescription` ("access to home data is not authorized" in meaning) |
| `performAccessorySetupUsingRequest:` with no home | `HMErrorDomain` 23 | empty |
| Missing usage string | No error: the process is aborted when the first manager is created | — |

Localized descriptions come from the framework's own string tables; an
open implementation writes its own text with the same meaning.

## 3. Mapping from accessory protocol status (design guidance)

HAP-IP reports per-characteristic status codes (`accessory-protocols.md`
§2.3). An open implementation should map them onto public codes. This
table is our proposal (Ycode-original), to be checked against the reference
with the HomeKit Accessory Simulator (`plan.md` HK-A20):

| HAP status | Meaning | Proposed `HMErrorCode` |
|---|---|---|
| −70401 | insufficient privileges | 17 InsufficientPrivileges |
| −70402 | unable to communicate with the service | 54 CommunicationFailure |
| −70403 | resource busy | 14 AccessoryIsBusy |
| −70404 | write to read-only | 5 ReadOnlyCharacteristic |
| −70405 | read from write-only | 6 WriteOnlyCharacteristic |
| −70406 | notification not supported | 7 NotificationNotSupported |
| −70407 | out of resources | 16 AccessoryOutOfResources |
| −70408 | operation timed out (not in the ADK file we read; verify) | 8 OperationTimedOut |
| −70409 | resource does not exist | 2 NotFound |
| −70410 | invalid value | 3 InvalidParameter |
| −70411 | insufficient authorization | 87 InvalidOrMissingAuthorizationData |
| (connection lost) | | 4 AccessoryNotReachable |

## Evidence

Level 4: code names, values, introduction versions. Level 3: §2 and the
remarks marked level 3 in §1. Level 1: meanings in §1 and HAP status
meanings in §3 (Apple's HomeKit ADK, Apache-2.0). §3 mapping column is a
Ycode-original proposal. No level 5.
