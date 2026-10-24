# HomeKit spec: type identifiers and value catalog

Part of `specs/frameworks/homekit/`. The identifier strings that HomeKit
exposes for services, characteristics, accessory categories, metadata
formats and units, characteristic properties, action-set types and
significant events, plus the numeric values of the characteristic value
enumerations. These are interop facts: apps compare `serviceType`,
`characteristicType`, `categoryType`, `format` and `units` against these
strings, and the service and characteristic UUIDs are the identifiers that
accessories send over the HomeKit Accessory Protocol.

Sources: every value below was read at run time by our probe (`HMProbe
-mode consts`, level 3) from the public constant of that name, on iOS 27.1
and 27.0 (identical). Constant names and introduction versions come from the
SDK (level 4). Seventeen characteristic short IDs were cross-checked against
Apple's open-source HomeKit ADK (Apache-2.0, level 1) and all matched.

## 1. UUID scheme

- Service and characteristic types are uppercase 128-bit UUID strings of
  the form `0000XXXX-0000-1000-8000-0026BB765291`: the Apple-defined HAP
  base UUID with a short ID of up to 32 bits in the first group. The tables
  give the short ID in hex without leading zeros (e.g. `43` means
  `00000043-0000-1000-8000-0026BB765291`). On the wire HAP-IP sends the
  short form for Apple-defined types and the full UUID for custom ones
  (`accessory-protocols.md` §2.3). An open implementation must accept both
  and always expose the full uppercase form through the API.
- Vendor-defined (custom) services and characteristics use any other UUID;
  HomeKit passes them through with that UUID as the type string.
- Accessory category types are **not** HAP category numbers: they are
  fixed random-looking UUID strings (table §3). The mapping from the HAP
  `ci` category number to these strings is an implementation table
  (`accessory-protocols.md` §2.5).
- No two public constants share a value. Four characteristic constants
  (Manufacturer, Model, SerialNumber, FirmwareVersion) are deprecated since
  iOS 11 in favor of `HMAccessory` properties; they still resolve.

"iOS" below is the introduction version from the SDK.

## 2. Services and characteristics

#### Service types (46)

| Short ID | Name (after `HMServiceType`) | iOS | Notes |
|---|---|---|---|
| 3E | AccessoryInformation | 8.0 |  |
| 40 | Fan | 8.0 |  |
| 41 | GarageDoorOpener | 8.0 |  |
| 43 | Lightbulb | 8.0 |  |
| 44 | LockManagement | 8.0 |  |
| 45 | LockMechanism | 8.0 |  |
| 47 | Outlet | 8.0 |  |
| 49 | Switch | 8.0 |  |
| 4A | Thermostat | 8.0 |  |
| 7E | SecuritySystem | 9.0 |  |
| 7F | CarbonMonoxideSensor | 9.0 |  |
| 80 | ContactSensor | 9.0 |  |
| 81 | Door | 9.0 |  |
| 82 | HumiditySensor | 9.0 |  |
| 83 | LeakSensor | 9.0 |  |
| 84 | LightSensor | 9.0 |  |
| 85 | MotionSensor | 9.0 |  |
| 86 | OccupancySensor | 9.0 |  |
| 87 | SmokeSensor | 9.0 |  |
| 88 | StatefulProgrammableSwitch | 9.0 |  |
| 89 | StatelessProgrammableSwitch | 9.0 |  |
| 8A | TemperatureSensor | 9.0 |  |
| 8B | Window | 9.0 |  |
| 8C | WindowCovering | 9.0 |  |
| 8D | AirQualitySensor | 9.0 |  |
| 96 | Battery | 9.0 |  |
| 97 | CarbonDioxideSensor | 9.0 |  |
| B7 | VentilationFan | 10.2 |  |
| B9 | Slats | 10.2 |  |
| BA | FilterMaintenance | 10.2 |  |
| BB | AirPurifier | 10.2 |  |
| BC | HeaterCooler | 10.2 |  |
| BD | HumidifierDehumidifier | 10.2 |  |
| CC | Label | 10.3 |  |
| CF | IrrigationSystem | 11.2 |  |
| D0 | Valve | 11.2 |  |
| D7 | Faucet | 11.2 |  |
| D8 | Television | 18.0 |  |
| D9 | InputSource | 18.0 |  |
| 110 | CameraRTPStreamManagement | 10.0 |  |
| 111 | CameraControl | 10.0 |  |
| 112 | Microphone | 10.0 |  |
| 113 | Speaker | 10.0 |  |
| 121 | Doorbell | 10.0 |  |
| 20A | WiFiRouter | 18.0 |  |
| 20F | WiFiSatellite | 18.0 |  |

#### Characteristic types (138)

| Short ID | Name (after `HMCharacteristicType`) | iOS | Notes |
|---|---|---|---|
| 1 | AdminOnlyAccess | 8.0 |  |
| 5 | AudioFeedback | 8.0 |  |
| 8 | Brightness | 8.0 |  |
| D | CoolingThreshold | 8.0 |  |
| E | CurrentDoorState | 8.0 |  |
| F | CurrentHeatingCooling | 8.0 |  |
| 10 | CurrentRelativeHumidity | 8.0 |  |
| 11 | CurrentTemperature | 8.0 |  |
| 12 | HeatingThreshold | 8.0 |  |
| 13 | Hue | 8.0 |  |
| 14 | Identify | 8.0 |  |
| 19 | LockManagementControlPoint | 8.0 |  |
| 1A | LockManagementAutoSecureTimeout | 8.0 |  |
| 1C | LockMechanismLastKnownAction | 8.0 |  |
| 1D | CurrentLockMechanismState | 8.0 |  |
| 1E | TargetLockMechanismState | 8.0 |  |
| 1F | Logs | 8.0 |  |
| 20 | Manufacturer | 8.0 | deprecated 11.0 |
| 21 | Model | 8.0 | deprecated 11.0 |
| 22 | MotionDetected | 8.0 |  |
| 23 | Name | 8.0 |  |
| 24 | ObstructionDetected | 8.0 |  |
| 25 | PowerState | 8.0 |  |
| 26 | OutletInUse | 8.0 |  |
| 28 | RotationDirection | 8.0 |  |
| 29 | RotationSpeed | 8.0 |  |
| 2F | Saturation | 8.0 |  |
| 30 | SerialNumber | 8.0 | deprecated 11.0 |
| 32 | TargetDoorState | 8.0 |  |
| 33 | TargetHeatingCooling | 8.0 |  |
| 34 | TargetRelativeHumidity | 8.0 |  |
| 35 | TargetTemperature | 8.0 |  |
| 36 | TemperatureUnits | 8.0 |  |
| 37 | Version | 8.0 |  |
| 52 | FirmwareVersion | 8.0 | deprecated 11.0 |
| 53 | HardwareVersion | 8.0 |  |
| 54 | SoftwareVersion | 9.0 |  |
| 64 | AirParticulateDensity | 9.0 |  |
| 65 | AirParticulateSize | 9.0 |  |
| 66 | CurrentSecuritySystemState | 9.0 |  |
| 67 | TargetSecuritySystemState | 9.0 |  |
| 68 | BatteryLevel | 9.0 |  |
| 69 | CarbonMonoxideDetected | 9.0 |  |
| 6A | ContactState | 9.0 |  |
| 6B | CurrentLightLevel | 9.0 |  |
| 6C | CurrentHorizontalTilt | 9.0 |  |
| 6D | CurrentPosition | 9.0 |  |
| 6E | CurrentVerticalTilt | 9.0 |  |
| 6F | HoldPosition | 9.0 |  |
| 70 | LeakDetected | 9.0 |  |
| 71 | OccupancyDetected | 9.0 |  |
| 72 | PositionState | 9.0 |  |
| 73 | InputEvent | 9.0 |  |
| 74 | OutputState | 9.0 |  |
| 75 | StatusActive | 9.0 |  |
| 76 | SmokeDetected | 9.0 |  |
| 77 | StatusFault | 9.0 |  |
| 78 | StatusJammed | 9.0 |  |
| 79 | StatusLowBattery | 9.0 |  |
| 7A | StatusTampered | 9.0 |  |
| 7B | TargetHorizontalTilt | 9.0 |  |
| 7C | TargetPosition | 9.0 |  |
| 7D | TargetVerticalTilt | 9.0 |  |
| 8E | SecuritySystemAlarmType | 9.0 |  |
| 8F | ChargingState | 9.0 |  |
| 90 | CarbonMonoxideLevel | 9.0 |  |
| 91 | CarbonMonoxidePeakLevel | 9.0 |  |
| 92 | CarbonDioxideDetected | 9.0 |  |
| 93 | CarbonDioxideLevel | 9.0 |  |
| 94 | CarbonDioxidePeakLevel | 9.0 |  |
| 95 | AirQuality | 9.0 |  |
| A7 | LockPhysicalControls | 10.2 |  |
| A8 | TargetAirPurifierState | 10.2 |  |
| A9 | CurrentAirPurifierState | 10.2 |  |
| AA | CurrentSlatState | 10.2 |  |
| AB | FilterLifeLevel | 10.2 |  |
| AC | FilterChangeIndication | 10.2 |  |
| AD | FilterResetChangeIndication | 10.2 |  |
| AF | CurrentFanState | 10.2 |  |
| B0 | Active | 10.2 |  |
| B1 | CurrentHeaterCoolerState | 10.2 |  |
| B2 | TargetHeaterCoolerState | 10.2 |  |
| B3 | CurrentHumidifierDehumidifierState | 10.2 |  |
| B4 | TargetHumidifierDehumidifierState | 10.2 |  |
| B5 | WaterLevel | 10.2 |  |
| B6 | SwingMode | 10.2 |  |
| BF | TargetFanState | 10.2 |  |
| C0 | SlatType | 10.2 |  |
| C1 | CurrentTilt | 10.2 |  |
| C2 | TargetTilt | 10.2 |  |
| C3 | OzoneDensity | 10.2 |  |
| C4 | NitrogenDioxideDensity | 10.2 |  |
| C5 | SulphurDioxideDensity | 10.2 |  |
| C6 | PM2_5Density | 10.2 |  |
| C7 | PM10Density | 10.2 |  |
| C8 | VolatileOrganicCompoundDensity | 10.2 |  |
| C9 | DehumidifierThreshold | 10.2 |  |
| CA | HumidifierThreshold | 10.2 |  |
| CB | LabelIndex | 10.3 |  |
| CD | LabelNamespace | 10.3 |  |
| CE | ColorTemperature | 11.0 |  |
| D1 | ProgramMode | 11.2 |  |
| D2 | InUse | 11.2 |  |
| D3 | SetDuration | 11.2 |  |
| D4 | RemainingDuration | 11.2 |  |
| D5 | ValveType | 11.2 |  |
| D6 | IsConfigured | 11.2 |  |
| DB | InputSourceType | 18.0 |  |
| DC | InputDeviceType | 18.0 |  |
| DD | ClosedCaptions | 18.0 |  |
| DF | PowerModeSelection | 18.0 |  |
| E0 | CurrentMediaState | 18.0 |  |
| E1 | RemoteKey | 18.0 |  |
| E2 | PictureMode | 18.0 |  |
| E3 | ConfiguredName | 18.0 |  |
| E6 | Identifier | 18.0 |  |
| E7 | ActiveIdentifier | 18.0 |  |
| E9 | VolumeControlType | 18.0 |  |
| EA | VolumeSelector | 18.0 |  |
| 114 | SupportedVideoStreamConfiguration | 10.0 |  |
| 115 | SupportedAudioStreamConfiguration | 10.0 |  |
| 116 | SupportedRTPConfiguration | 10.0 |  |
| 117 | SelectedStreamConfiguration | 10.0 |  |
| 118 | SetupStreamEndpoint | 10.0 |  |
| 119 | Volume | 10.0 |  |
| 11A | Mute | 10.0 |  |
| 11B | NightVision | 10.0 |  |
| 11C | OpticalZoom | 10.0 |  |
| 11D | DigitalZoom | 10.0 |  |
| 11E | ImageRotation | 10.0 |  |
| 11F | ImageMirroring | 10.0 |  |
| 120 | StreamingStatus | 10.0 |  |
| 134 | TargetVisibilityState | 18.0 |  |
| 135 | CurrentVisibilityState | 18.0 |  |
| 137 | TargetMediaState | 18.0 |  |
| 20E | RouterStatus | 18.0 |  |
| 212 | WANStatusList | 18.0 |  |
| 21E | WiFiSatelliteStatus | 18.0 |  |


## 3. Accessory categories

#### Accessory category types (33)

| Name (after `HMAccessoryCategoryType`) | Identifier string | iOS |
|---|---|---|
| AirConditioner | `18DDD63A-27F9-4341-B59B-759D3D114586` | 10.2 |
| AirDehumidifier | `1E15B639-DC98-41D4-A394-2E4A1D54AA3A` | 10.2 |
| AirHeater | `BF7036FD-93CF-49B5-954F-CD2B760D11DA` | 10.2 |
| AirHumidifier | `3FEB9075-C9AF-4629-ADBC-A853259C645A` | 10.2 |
| AirPort | `8BFB739C-1E09-4F7B-ABB8-DD7BADD0E8A9` | 18.0 |
| AirPurifier | `5510B997-D711-4636-870F-82BB61092B15` | 10.2 |
| AudioReceiver | `BE15659C-3CE6-4FD0-B152-BCDB488446C6` | 18.0 |
| Bridge | `61102194-9993-48BF-A1EF-6C7DC50F0C01` | 9.0 |
| Door | `DD4DE411-8F01-44EE-866A-1F96144DC1B6` | 9.0 |
| DoorLock | `C25D5FCE-52EC-4599-A815-1192C5F08C7F` | 9.0 |
| Fan | `151CB559-0DF9-40AA-8A67-12AF06C4449D` | 9.0 |
| Faucet | `43CE6F7E-F7E8-44B4-80CE-5786F6E6CD47` | 11.2 |
| GarageDoorOpener | `604B6E52-2C87-4596-B4C9-D15077C0C07F` | 9.0 |
| IPCamera | `C9EE63DB-2FF7-4514-826A-2FC2F0D4C9F0` | 10.0 |
| Lightbulb | `57D56F4D-3302-41F7-AB34-5365AA180E81` | 9.0 |
| Other | `0FBA259B-05AC-46F2-875F-204ABB6D9FE7` | 9.0 |
| Outlet | `730F40D4-6D0E-4903-B09E-520A08AFB78C` | 9.0 |
| ProgrammableSwitch | `3F9B944B-B8DF-4570-BAF5-CD31A8B321A7` | 9.0 |
| RangeExtender | `8E33483E-2102-4BFE-9295-0A187D114188` | 9.3 |
| SecuritySystem | `14D8FE28-2998-49E3-AC95-E3969BE2957C` | 9.0 |
| Sensor | `772AFB8E-8D2F-455E-90E5-9852E6C4DD31` | 9.0 |
| ShowerHead | `39D2A5B4-F9A6-43F6-90E7-0019F0C0E99F` | 11.2 |
| Speaker | `C0F5EDC5-4003-464A-9E5D-0DB36677BC35` | 18.0 |
| Sprinkler | `94D3FBD5-0A74-4EE4-BE1A-C97E82ADFA33` | 11.2 |
| Switch | `2F4C3164-8DE4-4A4F-93BA-DD1D5068DF0B` | 9.0 |
| Television | `830C0952-7CD8-44FB-B0C0-DA4EDB0F32A9` | 18.0 |
| TelevisionSetTopBox | `FB953A08-6CDD-44E0-B011-CFAC559A3CFB` | 18.0 |
| TelevisionStreamingStick | `B0C866C4-3E25-4F6A-8476-A8A3B579A86E` | 18.0 |
| Thermostat | `79668DCF-89FB-450D-94B5-AEE70B7B09F1` | 9.0 |
| VideoDoorbell | `957A52E0-BE03-490C-8305-7B20C1CC17BA` | 10.0 |
| WiFiRouter | `337635B4-552A-48AD-A38D-DD2D5E826C9A` | 18.0 |
| Window | `1C501511-408E-4C1E-816B-3FC011FFD5B1` | 9.0 |
| WindowCovering | `2FB9EE1F-1C21-4D0B-9383-9B65F64DBF0E` | 9.0 |


## 4. Metadata strings, properties, action sets, significant events

The format strings are HAP's JSON format names (`bool`, `uint8`, `uint16`,
`uint32`, `uint64`, `int`, `float`, `string`, `tlv8`, `data`) plus
HomeKit's own `array` and `dict`. The unit strings are HAP's unit names
(`celsius`, `percentage`, `arcdegrees`, `lux`, `seconds`) plus HomeKit's
`fahrenheit`, `ppm` and `micrograms/m^3`.
Property and action-set constants are equal to their own names.

#### Metadata formats (12)

| Name (after `HMCharacteristicMetadataFormat`) | Identifier string | iOS |
|---|---|---|
| Array | `array` | 8.0 |
| Bool | `bool` | 8.0 |
| Data | `data` | 8.0 |
| Dictionary | `dict` | 8.0 |
| Float | `float` | 8.0 |
| Int | `int` | 8.0 |
| String | `string` | 8.0 |
| TLV8 | `tlv8` | 8.0 |
| UInt16 | `uint16` | 8.0 |
| UInt32 | `uint32` | 8.0 |
| UInt64 | `uint64` | 8.0 |
| UInt8 | `uint8` | 8.0 |

#### Metadata units (8)

| Name (after `HMCharacteristicMetadataUnits`) | Identifier string | iOS |
|---|---|---|
| ArcDegree | `arcdegrees` | 8.0 |
| Celsius | `celsius` | 8.0 |
| Fahrenheit | `fahrenheit` | 8.0 |
| Lux | `lux` | 9.3 |
| MicrogramsPerCubicMeter | `micrograms/m^3` | 10.0 |
| PartsPerMillion | `ppm` | 10.0 |
| Percentage | `percentage` | 8.0 |
| Seconds | `seconds` | 8.3 |

#### Characteristic properties (5)

| Name (after `HMCharacteristicProperty`) | Identifier string | iOS |
|---|---|---|
| Hidden | `HMCharacteristicPropertyHidden` | 9.3 |
| Readable | `HMCharacteristicPropertyReadable` | 8.0 |
| RequiresAuthorizationData | `HMCharacteristicPropertyRequiresAuthorizationData` | 18.0 |
| SupportsEventNotification | `HMCharacteristicPropertySupportsEventNotification` | 8.0 |
| Writable | `HMCharacteristicPropertyWritable` | 8.0 |

#### Action-set types (6)

| Name (after `HMActionSetType`) | Identifier string | iOS |
|---|---|---|
| HomeArrival | `HMActionSetTypeHomeArrival` | 9.0 |
| HomeDeparture | `HMActionSetTypeHomeDeparture` | 9.0 |
| Sleep | `HMActionSetTypeSleep` | 9.0 |
| TriggerOwned | `HMActionSetTypeTriggerOwned` | 10.0 |
| UserDefined | `HMActionSetTypeUserDefined` | 9.0 |
| WakeUp | `HMActionSetTypeWakeUp` | 9.0 |

#### Significant events (2)

| Name (after `HMSignificantEvent`) | Identifier string | iOS |
|---|---|---|
| Sunrise | `sunrise` | 9.0 |
| Sunset | `sunset` | 9.0 |

Key-path strings for event-trigger predicates: `HMCharacteristicKeyPath` =
`characteristic`, `HMCharacteristicValueKeyPath` = `characteristicValue`,
`HMPresenceKeyPath` = `presence`. `HMErrorDomain` = `HMErrorDomain`.
`HMUserFailedAccessoriesKey` equals its name (deprecated iOS 27).

## 5. Characteristic value enumerations

Values an app reads from or writes to enumerated characteristics (as
`NSNumber`). Columns: enumeration name after the `HMCharacteristicValue`
prefix, introduction version, and `value Name` pairs with the enumeration
prefix removed. These numbers equal the HAP wire values of the matching
characteristics (level 1, HomeKit ADK).

| Enumeration | iOS | Values |
|---|---|---|
| LockMechanismLastKnownAction | 8.0 | 0 SecuredUsingPhysicalMovementInterior, 1 UnsecuredUsingPhysicalMovementInterior, 2 SecuredUsingPhysicalMovementExterior, 3 UnsecuredUsingPhysicalMovementExterior, 4 SecuredWithKeypad, 5 UnsecuredWithKeypad, 6 SecuredRemotely, 7 UnsecuredRemotely, 8 SecuredWithAutomaticSecureTimeout, 9 SecuredUsingPhysicalMovement, 10 UnsecuredUsingPhysicalMovement |
| AirParticulateSize | 9.0 | 0 2_5, 1 10 |
| AirQuality | 9.0 | 0 Unknown, 1 Excellent, 2 Good, 3 Fair, 4 Inferior, 5 Poor |
| PositionState | 9.0 | 0 Closing, 1 Opening, 2 Stopped |
| CurrentSecuritySystemState | 9.0 | 0 StayArm, 1 AwayArm, 2 NightArm, 3 Disarmed, 4 Triggered |
| TargetSecuritySystemState | 9.0 | 0 StayArm, 1 AwayArm, 2 NightArm, 3 Disarm |
| JammedStatus | 10.0 | 0 None, 1 Jammed |
| TamperedStatus | 10.0 | 0 None, 1 Tampered |
| LeakStatus | 10.0 | 0 None, 1 Detected |
| ContactState | 10.0 | 0 Detected, 1 None |
| StatusFault | 10.0 | 0 NoFault, 1 GeneralFault |
| CarbonMonoxideDetectionStatus | 10.0 | 0 NotDetected, 1 Detected |
| CarbonDioxideDetectionStatus | 10.0 | 0 NotDetected, 1 Detected |
| OccupancyStatus | 10.0 | 0 NotOccupied, 1 Occupied |
| SecuritySystemAlarmType | 10.0 | 0 NoAlarm, 1 Unknown |
| CurrentAirPurifierState | 10.2 | 0 Inactive, 1 Idle, 2 Active |
| TargetAirPurifierState | 10.2 | 0 Manual, 1 Automatic |
| CurrentSlatState | 10.2 | 0 Stationary, 1 Jammed, 2 Oscillating |
| SlatType | 10.2 | 0 Horizontal, 1 Vertical |
| FilterChange | 10.2 | 0 NotNeeded, 1 Needed |
| LabelNamespace | 10.3 | 0 Dot, 1 Numeral |
| ProgramMode | 11.2 | 0 NotScheduled, 1 Scheduled, 2 ScheduleOverriddenToManual |
| UsageState | 11.2 | 0 NotInUse, 1 InUse |
| ValveType | 11.2 | 0 GenericValve, 1 Irrigation, 2 ShowerHead, 3 WaterFaucet |
| VolumeControlType | 18.0 | 0 None, 1 Relative, 2 RelativeWithCurrent, 3 Absolute |
| VolumeSelector | 18.0 | 0 VolumeIncrement, 1 VolumeDecrement |
| DoorState | 8.0 | 0 Open, 1 Closed, 2 Opening, 3 Closing, 4 Stopped |
| CurrentHeatingCooling | 8.0 | 0 Off, 1 Heat, 2 Cool |
| LockMechanismState | 8.0 | 0 Unsecured, 1 Secured, 2 Jammed, 3 Unknown |
| TargetLockMechanismState | 8.0 | 0 Unsecured, 1 Secured |
| RotationDirection | 8.0 | 0 Clockwise, 1 CounterClockwise |
| TargetDoorState | 8.0 | 0 Open, 1 Closed |
| HeatingCooling | 8.0 | 0 Off, 1 Heat, 2 Cool, 3 Auto |
| TemperatureUnit | 8.0 | 0 Celsius, 1 Fahrenheit |
| InputEvent | 10.3 | 0 SinglePress, 1 DoublePress, 2 LongPress |
| SmokeDetectionStatus | 10.0 | 0 None, 1 Detected |
| BatteryStatus | 10.0 | 0 Normal, 1 Low |
| ChargingState | 10.0 | 0 None, 1 InProgress, 2 NotChargeable |
| LockPhysicalControlsState | 10.2 | 0 NotLocked, 1 Locked |
| CurrentFanState | 10.2 | 0 Inactive, 1 Idle, 2 Active |
| ActivationState | 10.2 | 0 Inactive, 1 Active |
| CurrentHeaterCoolerState | 10.2 | 0 Inactive, 1 Idle, 2 Heating, 3 Cooling |
| TargetHeaterCoolerState | 10.2 | 0 Automatic, 1 Heat, 2 Cool |
| CurrentHumidifierDehumidifierState | 10.2 | 0 Inactive, 1 Idle, 2 Humidifying, 3 Dehumidifying |
| TargetHumidifierDehumidifierState | 10.2 | 0 Automatic, 1 Humidify, 2 Dehumidify |
| SwingMode | 10.2 | 0 Disabled, 1 Enabled |
| TargetFanState | 10.2 | 0 Manual, 1 Automatic |
| ConfigurationState | 11.2 | 0 NotConfigured, 1 Configured |
| InputSourceType | 18.0 | 0 Other, 1 HomeScreen, 2 Tuner, 3 HDMI, 4 CompositeVideo, 5 SVideo, 6 ComponentVideo, 7 DVI, 8 AirPlay, 9 USB, 10 Application |
| InputDeviceType | 18.0 | 0 Other, 1 TV, 2 Recording, 3 Tuner, 4 Playback, 5 AudioSystem, 6 None |
| ClosedCaptions | 18.0 | 0 Disabled, 1 Enabled |
| PowerModeSelection | 18.0 | 0 Show, 1 Hide |
| CurrentMediaState | 18.0 | 0 Playing, 1 Paused, 2 Stopped, 3 Unknown, 4 Loading, 5 Interrupted |
| RemoteKey | 18.0 | 0 Rewind, 1 FastForward, 2 NextTrack, 3 PreviousTrack, 4 ArrowUp, 5 ArrowDown, 6 ArrowLeft, 7 ArrowRight, 8 Select, 9 Back, 10 Exit, 11 PlayPause, 12 Play, 13 Pause, 14 Menu, 15 Info, 16 Home |
| PictureMode | 18.0 | 0 Standard, 1 Movie, 2 Sport, 3 Game, 4 Photo, 5 Vivid, 6 Dark, 7 Bright, 8 Computer, 9 Night, 10 Calibrated, 11 Custom1, 12 Custom2, 13 Custom3 |
| TargetVisibilityState | 18.0 | 0 Show, 1 Hide |
| CurrentVisibilityState | 18.0 | 0 Shown, 1 Hidden, 2 Connected, 3 AlwaysShown |
| TargetMediaState | 18.0 | 0 Play, 1 Pause, 2 Stop |
| RouterStatus | 18.0 | 0 Ready, 1 NotReady |
| WiFiSatelliteStatus | 18.0 | 0 Unknown, 1 Connected, 2 NotConnected |

## Evidence

Level 3: every identifier string (§§2–4), read by `HMProbe` on iOS 27.1 and
27.0. Level 4: constant names, introduction and deprecation versions, enum
member names and values (§5). Level 1: HAP base UUID and short-ID
cross-check against HomeKit ADK, wire equivalence of enum values (§§1, 5).
No level 5.
