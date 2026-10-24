# xcodebuild: command-line grammar, errors and exit codes

Ycode tool: `ycodebuild` (module `YcodeXcodebuild`, executable
`ycode/Sources/ycodebuild`). It accepts the same command lines as
`xcodebuild`, prints the same output formats and returns the same exit
codes, so that scripts and CI jobs written for `xcodebuild` keep working.
It never runs `xcodebuild` to do its work.

Related specs: `info-commands.md` (-version, -list, -showsdks,
-showdestinations, -help), `show-build-settings.md`, `build-actions.md`.

## 1. Words on the command line

Every argument is classified, left to right, as one of:

| Form | Meaning |
|---|---|
| `-name` (one dash) | an option; options that take a value consume the next argument |
| `-name=value` | the same as `-name value` for value options (`-scheme=Tool` works) |
| `-userdefault=value` (not an option name) | a user default for this run only (documented in `xcodebuild(1)`); never an error, an empty name is ignored. ycodebuild uses `IDECustomDerivedDataLocation` (the folder that holds each container's DerivedData folder, instead of `~/Library/Developer/Xcode/DerivedData`) and ignores the others |
| `NAME=value` (contains `=`, does not start with `-`) | a build-setting override. The text before the first `=` is the name, the rest the value. An empty name (`=x`) is accepted and ignored. Names are case-sensitive (`foo=bar` is a different setting from `FOO`). |
| anything else | a build action word |

There are no `--long` options: `--list` is an invalid option.

### Build actions

`build`, `build-for-testing`, `analyze`, `archive`, `test`,
`test-without-building`, `docbuild`, `installsrc`, `install`, `clean`.
Several may be given (`clean build`); they run in order. With no action
word and no info option, the action is `build`. Any other word is an error
(§4, "Unknown build action").

### Options

`V` = takes one value. `M` = may be repeated. Options not marked `M` may
appear only once.

| Option | Arity | Effect in ycodebuild |
|---|---|---|
| `-usage` | | brief usage (usage lines only) on stderr, exit 0 |
| `-help` | | usage lines and the option table on stderr, exit 0 |
| `-verbose` | | accepted; more status output |
| `-quiet` | | only warnings and errors (and the requested data) are printed; no "Command line invocation" header |
| `-json` | | JSON output for `-list`, `-showBuildSettings`, `-showsdks`, `-version -sdk`; implies `-quiet` for build actions |
| `-version` | | version info (see info-commands.md) |
| `-list` | | targets/configurations/schemes |
| `-showsdks` | | installed SDKs |
| `-showdestinations` | | run destinations for a scheme |
| `-showTestPlans` | | test plans of a scheme |
| `-showBuildSettings` | | resolved build settings |
| `-showBuildSettingsForIndex` | | not supported (error) |
| `-project` | V | the `.xcodeproj` |
| `-workspace` | V | the `.xcworkspace` |
| `-scheme` | V | the scheme |
| `-target` | V M | a target (legacy, no scheme) |
| `-alltargets` | | all targets (legacy) |
| `-configuration` | V | build configuration |
| `-xcconfig` | V | an xcconfig whose assignments act as overrides |
| `-arch` | V M | overrides `ARCHS` |
| `-sdk` | V | overrides `SDKROOT` (name or path); with `-version`, selects SDKs |
| `-toolchain` | V | toolchain name or identifier |
| `-destination` | V M | destination specifier `key=value[,key=value]` |
| `-destination-timeout` | V | seconds |
| `-parallelizeTargets` | | build independent targets in parallel |
| `-jobs` | V | maximum concurrent tasks; must be ≥ 1 |
| `-derivedDataPath` | V | DerivedData directory |
| `-resultBundlePath` | V | write a result bundle (`result-bundle.md`) |
| `-resultStreamPath`, `-resultBundleVersion` | V | accepted (no result stream is written) |
| `-archivePath`, `-exportPath`, `-exportOptionsPlist`, `-importPath` | V | archive/export paths |
| `-exportArchive` | | export an archive (`archive.md` §4; ad hoc signing only) |
| `-exportNotarizedApp` | | not supported yet |
| `-clonedSourcePackagesDirPath`, `-packageCachePath`, `-defaultPackageRegistryURL`, `-packageDependencySCMToRegistryTransformation`, `-packageFingerprintPolicy`, `-packageSigningEntityPolicy`, `-packageAuthorizationProvider`, `-scmProvider` | V | package options, accepted |
| `-resolvePackageDependencies`, `-disableAutomaticPackageResolution`, `-onlyUsePackageVersionsFromResolvedFile`, `-skipPackageUpdates`, `-disablePackageRepositoryCache`, `-skipPackagePluginValidation`, `-skipMacroValidation`, `-skipPackageSignatureValidation` | | package flags, accepted |
| `-testPlan`, `-xctestrun`, `-testProductsPath`, `-only-testing`, `-skip-testing`, `-only-test-configuration`, `-skip-test-configuration`, `-testLanguage`, `-testRegion`, `-test-iterations`, `-collect-test-diagnostics`, `-test-enumeration-style`, `-test-enumeration-format`, `-test-enumeration-output-path`, `-default-test-execution-time-allowance`, `-maximum-test-execution-time-allowance`, `-maximum-concurrent-test-device-destinations`, `-maximum-concurrent-test-simulator-destinations`, `-parallel-testing-worker-count`, `-maximum-parallel-testing-workers` | V (M for the `-only`/`-skip` ones) | test options; also the attached form `-only-testing:ID` |
| `-parallel-testing-enabled`, `-test-timeouts-enabled`, `-test-repetition-relaunch-enabled`, `-enableAddressSanitizer`, `-enableThreadSanitizer`, `-enableUndefinedBehaviorSanitizer`, `-enableCodeCoverage`, `-enableCodesizeProfile`, `-enablePerformanceTestsDiagnostics` | V (`YES`/`NO`) | accepted |
| `-retry-tests-on-failure`, `-run-tests-until-failure`, `-enumerate-tests`, `-skipUnavailableActions`, `-hideShellScriptEnvironment`, `-showBuildTimingSummary`, `-allowProvisioningUpdates`, `-allowProvisioningDeviceRegistration` | | accepted |
| `-authenticationKeyPath`, `-authenticationKeyID`, `-authenticationKeyIssuerID`, `-codesizeProfileOutputDir` | V | accepted |
| `-exportLocalizations`, `-importLocalizations` | | localization catalogs (`localization.md`) |
| `-mergeImport`, `-includeScreenshots` | | accepted |
| `-localizationPath`, `-exportLanguage` (M), `-defaultLanguage` | V | localization |
| `-create-xcframework` | | not supported yet; `-framework`, `-library`, `-headers`, `-output`, `-debug-symbols` (V M) follow it |
| `-find-executable`, `-find-library` | V | not supported yet |
| `-license`, `-checkFirstLaunchStatus`, `-runFirstLaunch`, `-checkForNewerComponents`, `-downloadAllPlatforms`, `-prepareDeviceSupport` | | Xcode installation management: not supported (error naming the gap) |
| `-downloadPlatform`, `-importPlatform`, `-downloadComponent`, `-importComponent`, `-deleteComponent`, `-showComponent`, `-buildVersion`, `-architectureVariant`, `-platform`, `-osVersion`, `-modelCode`, `-architecture`, `-convert-project` | V | Xcode installation management: not supported |
| `-dry-run` | | removed option: error "option '-dry-run' is no longer supported" |

Value-option checks done while parsing: a value option at the end of the
line is an error ("requires an argument"); `-sdk` without a value is
allowed only together with `-version`; `-jobs` must parse as an integer
≥ 1.

## 2. Usage text

`-usage` prints the usage block; `-help` prints the usage block, a blank
line, `Options:` and one line per option, then a section describing the
`-exportOptionsPlist` keys. All of it goes to **stderr**; exit status 0.

The usage block is the following grammar, one form per line, the first
prefixed `Usage: ` and the rest indented to align (7 spaces):

    xcodebuild [-project <projectname>] [[-target <targetname>]...|-alltargets] [-configuration <configurationname>] [-arch <architecture>]... [-sdk [<sdkname>|<sdkpath>]] [-showBuildSettings [-json]] [<buildsetting>=<value>]... [<buildaction>]...
    xcodebuild [-project <projectname>] -scheme <schemeName> [-destination <destinationspecifier>]... [-configuration <configurationname>] [-arch <architecture>]... [-sdk [<sdkname>|<sdkpath>]] [-showBuildSettings [-json]] [-showdestinations] [<buildsetting>=<value>]... [<buildaction>]...
    xcodebuild -workspace <workspacename> -scheme <schemeName> [-destination <destinationspecifier>]... [-configuration <configurationname>] [-arch <architecture>]... [-sdk [<sdkname>|<sdkpath>]] [-showBuildSettings] [-showdestinations] [<buildsetting>=<value>]... [<buildaction>]...
    xcodebuild -version [-sdk [<sdkfullpath>|<sdkname>] [-json] [<infoitem>] ]
    xcodebuild -list [[-project <projectname>]|[-workspace <workspacename>]] [-json]
    xcodebuild -showsdks [-json]
    xcodebuild -exportArchive -archivePath <xcarchivepath> [-exportPath <destinationpath>] -exportOptionsPlist <plistpath>
    … (one line each for -exportNotarizedApp, -exportLocalizations, -importLocalizations, -resolvePackageDependencies, -create-xcframework, -downloadPlatform, -downloadAllPlatforms, -importPlatform, -downloadComponent, -importComponent, -deleteComponent, -showComponent)

The usage lines are an interface grammar and are reproduced verbatim (the
tool name in them is the interop command name). The option descriptions in
ycodebuild's `-help` are Ycode's own wording: a line is
`    -<option> <ARG>` padded to column 61, then the description. The
`-exportOptionsPlist` key section is not reproduced; ycodebuild prints the
key names only.

## 3. The "Command line invocation" header

Every non-quiet run that opens a container (project/workspace commands,
build actions, `-list`, `-showBuildSettings`, `-showdestinations`) starts
stdout with:

    Command line invocation:
        <absolute path of the tool> <arguments as given, space-separated>
    <blank line>

`-version`, `-showsdks`, `-help`, `-usage` and errors found while parsing
(exit 64 cases in §4 that are detected before any container is opened)
print no header. With `-quiet` or `-json` the header is omitted.
Arguments are printed as given, separated by single spaces. An argument
made only of ASCII letters and digits, non-ASCII characters and
`, + = - _ . /` is printed bare (`-destination platform=macOS`, `I=a,b`,
`Z=é`); any other argument, including an empty one, is enclosed in double
quotes with `"` and `\` escaped by a backslash (`"kleinian hybrid.xcodeproj"`,
`"J=a:b"`, `"Q=a\\b"`, `"C=q\"r"`). Characters observed to force quotes:
space, tab, `$ " ' ; ( ) * : @ % ~ # ! \ { } [ ] ^ & | < > ?` and backquote.

ycodebuild prints its own executable path here.

## 4. Errors and exit codes

Exit codes follow BSD `sysexits.h`: 0 success, 64 `EX_USAGE`, 65
`EX_DATAERR`, 66 `EX_NOINPUT`, 70 `EX_SOFTWARE`, 78 `EX_CONFIG`. A failed
build action also exits 65.

Error lines go to stderr as `xcodebuild: error: <message>`. ycodebuild
prints exactly this prefix (it is part of the interface scripts grep for).
Errors marked *+usage* are followed by a blank line and the `-help` text
without the export-options section. Messages (literal text, with
`<…>` placeholders):

| Situation | Message | Exit |
|---|---|---|
| unknown option | `invalid option '<opt>'` *+usage* | 64 |
| value option at the end | `option '<opt>' requires an argument` *+usage* | 64 |
| option given twice | `option '<opt>' may only be provided once` *+usage* | 64 |
| `-dry-run` | `option '-dry-run' is no longer supported` *+usage* | 64 |
| `-sdk` with no value, without `-version` | `-sdk must be supplied with an argument unless used with -version` | 64 |
| `-jobs` < 1 or not a number | `You cannot specify -jobs with less than 1 job.` | 64 |
| `-project` and `-workspace` | `You cannot specify both an Xcode project and a workspace.` | 64 |
| `-alltargets` and `-target` | `You cannot specify -alltargets and also specify individual targets.` | 64 |
| `-workspace` without `-scheme` (build actions, `-showBuildSettings`) | `If you specify a workspace then you must also specify a scheme.  Use -list to see the schemes in this workspace.` (two spaces after the first period) | 64 |
| `-derivedDataPath` without `-scheme` | `The flag -scheme, -testProductsPath, or -xctestrun is required when specifying -derivedDataPath.` | 64 |
| `-exportArchive` without its flags | one line per missing flag: `The flag -exportOptionsPlist is required when specifying -exportArchive.`, `The flag -archivePath is required when specifying -exportArchive.` | 64 |
| `-sdk` that matches no installed SDK | `SDK "<value>" cannot be located.` | 64 |
| `-showdestinations` without a scheme | `-showdestinations requires a workspace and scheme.` | 64 |
| `installsrc` with `-scheme` | `Cannot use the installsrc action with -scheme.` | 64 |
| `-project`/`-workspace` path missing | `'<path as given>' does not exist.` | 66 |
| `-project` path exists but is not a `.xcodeproj` directory | `'<absolute path>' is not a project file.` | 66 |
| no container in the working directory | `The directory <cwd> does not contain an Xcode project.` (with `-scheme` or `-list`: `… does not contain an Xcode project, workspace or package.`) followed by a blank line | 66 |
| several projects in the working directory | `The directory <cwd> contains <n> projects, including multiple projects with the current extension (.xcodeproj). Specify the project to use with the -project option.` followed by a blank line | 78 |
| unknown action word | `Unknown build action '<word>'.` | 65 |
| scheme not found (project) | `The project named "<name>" does not contain a scheme named "<scheme>". The "-list" option can be used to find the names of the schemes in the project.` | 65 |
| scheme not found (workspace) | `The workspace named "<name>" does not contain a scheme named "<scheme>". The "-list" option can be used to find the names of the schemes in the workspace.` | 65 |
| target not found | `The project '<file name>.xcodeproj' does not contain a target named '<target>'.` | 65 |
| `test` without a scheme | `The test action requires that the name of a scheme in the project is provided using the "-scheme" option. The "-list" option can be used to find the names of the schemes in the project.` | 65 |
| scheme has no test action entries | `Scheme <name> is not currently configured for the test action.` followed by a blank line | 66 |
| `-resultBundlePath` names an existing path | `Existing file at -resultBundlePath "<path>"` (before the header) | 64 |

Errors detected after the container is opened (65, 66, 78 rows except the
parse-time ones) come after the "Command line invocation" header on stdout.

Warnings use the prefix `--- xcodebuild: WARNING: ` on stderr:

| Situation | Warning |
|---|---|
| `-configuration` not in the project (legacy and scheme runs) | `Configuration <name> is not in the project. Building default configuration.` followed by a blank line |
| `-destination` without a scheme | `Ignoring provided run destination because no scheme was passed.` |

`xcodebuild` itself also writes a time-stamped "Writing error result bundle
to …" log line and some framework log lines to stderr. ycodebuild does not
print these.

## 5. What ycodebuild does not support yet

Each of these exits 70 (`EX_SOFTWARE`) with `xcodebuild: error: ycodebuild
does not support <feature> yet.`: `-exportNotarizedApp`,
`-create-xcframework`, `-find-executable`,
`-find-library`, `-showBuildSettingsForIndex`,
Xcode installation management (`-license`, `-runFirstLaunch`,
`-downloadPlatform` …), and the action `installsrc`.
`-exportArchive` supports only ad hoc signed application archives with
method `mac-application` (`archive.md` §4); `test` does not run
application-hosted or UI tests (`test-actions.md`). Without the `ycode-swb` helper, build actions and swift-build
evaluation are unavailable: build actions exit 70 naming the helper.
Swift packages opened directly and `-resolvePackageDependencies`:
`packages.md`.
The difference in exit code (70, where `xcodebuild` would do the work) is
deliberate: it lets a CI script tell a Ycode gap from a build failure.

## Evidence

- Option names and the usage grammar: `xcodebuild -help` and `-usage`
  output and `man xcodebuild` (level 1, public documentation shipped with
  the tool).
- `-userdefault=value`: `man xcodebuild` (level 1); acceptance of unknown
  and empty names, and `-IDECustomDerivedDataLocation=<dir>` placing the
  DerivedData folder under `<dir>`: black-box runs (level 3).
- Classification of words, `-name=value`, `--list`, empty setting names,
  repeated options, every message and exit code in §4, header placement and
  stderr/stdout split: black-box runs of `xcodebuild` 27.1 (27A9269) on
  hand-written sample projects (level 3).
- `sysexits.h` meanings: the BSD header (level 1).
- OPEN QUESTION: which options besides `-configuration` reject a second
  occurrence (only `-configuration` was probed).
- OPEN QUESTION: messages for `-scheme` together with `-target`
  (xcodebuild accepts it and uses the target; ycodebuild does the same).
- OPEN QUESTION: the exact `-showComponent`/`-license` behaviors (out of
  scope for Ycode).
