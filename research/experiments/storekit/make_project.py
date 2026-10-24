#!/usr/bin/env python3
"""Black-box probe: generate our own minimal iOS app project around StoreProbe
(main.swift and YcodeProbe.storekit from this folder) with one shared scheme
whose Run action names the StoreKit configuration file, plus a hosted unit
test target. Used to observe how Xcode and xcodebuild apply a scheme's
StoreKit configuration. Everything written is our own text.

Usage: python3 -I make_project.py OUTDIR [--ref RELPATH] [--test-ref RELPATH]
  --ref       identifier written into LaunchAction's StoreKitConfigurationFileReference
              (default ../../StoreProbe/YcodeProbe.storekit)
  --test-ref  same element inside TestAction (default: none)
"""
import os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    a = sys.argv[1:]
    out = a[0]
    ref = "../../StoreProbe/YcodeProbe.storekit"
    tref = None
    if "--ref" in a:
        ref = a[a.index("--ref") + 1]
    if "--test-ref" in a:
        tref = a[a.index("--test-ref") + 1]
    plat = subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-platform-path"],
                          capture_output=True, text=True).stdout.strip()
    os.makedirs(os.path.join(out, "StoreProbe"), exist_ok=True)
    os.makedirs(os.path.join(out, "StoreProbeTests"), exist_ok=True)
    shutil.copy(os.path.join(HERE, "StoreProbe", "main.swift"), os.path.join(out, "StoreProbe", "main.swift"))
    shutil.copy(os.path.join(HERE, "StoreProbe", "YcodeProbe.storekit"), os.path.join(out, "StoreProbe", "YcodeProbe.storekit"))
    open(os.path.join(out, "StoreProbeTests", "ProbeTests.swift"), "w").write(TEST)
    proj = os.path.join(out, "SKProj.xcodeproj")
    os.makedirs(os.path.join(proj, "xcshareddata", "xcschemes"), exist_ok=True)
    open(os.path.join(proj, "project.pbxproj"), "w").write(PBX)
    tr = ""
    if tref:
        tr = f'''      <StoreKitConfigurationFileReference
         identifier = "{tref}">
      </StoreKitConfigurationFileReference>
'''
    open(os.path.join(proj, "xcshareddata", "xcschemes", "StoreProbe.xcscheme"), "w").write(
        SCHEME.replace("@REF@", ref).replace("@TREF@", tr).replace("@FW@", plat + "/Developer/Library/Frameworks"))
    print("wrote", proj)


TEST = '''import XCTest
import StoreKit

final class ProbeTests: XCTestCase {
    func testLoadWithoutSession() async throws {
        let ids = ["dev.ycode.skprobe.coins100", "dev.ycode.skprobe.pro", "dev.ycode.skprobe.plus.monthly"]
        let ps = try await Product.products(for: ids)
        print("YCODE-TEST products=\\(ps.count) \\(ps.map { $0.id }.sorted())")
        var n = 0
        for await _ in Transaction.all { n += 1 }
        print("YCODE-TEST transactions=\\(n)")
    }
}
'''

PBX = r'''// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {
		F1 = {isa = PBXFileSystemSynchronizedRootGroup; path = StoreProbe; sourceTree = "<group>"; };
		F2 = {isa = PBXFileSystemSynchronizedRootGroup; path = StoreProbeTests; sourceTree = "<group>"; };
		R1 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = StoreProbe.app; sourceTree = BUILT_PRODUCTS_DIR; };
		R2 = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = StoreProbeTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
		G0 = {isa = PBXGroup; children = (F1, F2, G1, ); sourceTree = "<group>"; };
		G1 = {isa = PBXGroup; children = (R1, R2, ); name = Products; sourceTree = "<group>"; };
		S1 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
		B1 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
		K1 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
		S2 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
		T1 = {isa = PBXNativeTarget; buildConfigurationList = L1; buildPhases = (S1, K1, B1, ); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = (F1, ); name = StoreProbe; productName = StoreProbe; productReference = R1; productType = "com.apple.product-type.application"; };
		D1 = {isa = PBXContainerItemProxy; containerPortal = P0; proxyType = 1; remoteGlobalIDString = T1; remoteInfo = StoreProbe; };
		D2 = {isa = PBXTargetDependency; target = T1; targetProxy = D1; };
		T2 = {isa = PBXNativeTarget; buildConfigurationList = L2; buildPhases = (S2, ); buildRules = (); dependencies = (D2, ); fileSystemSynchronizedGroups = (F2, ); name = StoreProbeTests; productName = StoreProbeTests; productReference = R2; productType = "com.apple.product-type.bundle.unit-test"; };
		P0 = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 2700; LastUpgradeCheck = 2700; TargetAttributes = {T1 = {CreatedOnToolsVersion = 27.0; }; T2 = {CreatedOnToolsVersion = 27.0; TestTargetID = T1; }; }; }; buildConfigurationList = L0; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = G0; minimizedProjectReferenceProxies = 1; preferredProjectObjectVersion = 77; productRefGroup = G1; projectDirPath = ""; projectRoot = ""; targets = (T1, T2, ); };
		C0 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 27.0; SWIFT_VERSION = 5.0; CODE_SIGN_STYLE = Manual; CODE_SIGN_IDENTITY = "-"; DEVELOPMENT_TEAM = ""; ONLY_ACTIVE_ARCH = YES; DEBUG_INFORMATION_FORMAT = dwarf; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ENABLE_TESTABILITY = YES; }; name = Debug; };
		C1 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 27.0; SWIFT_VERSION = 5.0; CODE_SIGN_STYLE = Manual; CODE_SIGN_IDENTITY = "-"; DEVELOPMENT_TEAM = ""; }; name = Release; };
		C2 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = dev.ycode.skprobe; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; MARKETING_VERSION = 1.2; CURRENT_PROJECT_VERSION = 12; TARGETED_DEVICE_FAMILY = "1,2"; OTHER_SWIFT_FLAGS = "-parse-as-library"; FRAMEWORK_SEARCH_PATHS = "$(SDKROOT)/Developer/Library/Frameworks"; OTHER_LDFLAGS = "-framework StoreKitTest"; }; name = Debug; };
		C3 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = dev.ycode.skprobe; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; MARKETING_VERSION = 1.2; CURRENT_PROJECT_VERSION = 12; TARGETED_DEVICE_FAMILY = "1,2"; OTHER_SWIFT_FLAGS = "-parse-as-library"; FRAMEWORK_SEARCH_PATHS = "$(SDKROOT)/Developer/Library/Frameworks"; OTHER_LDFLAGS = "-framework StoreKitTest"; }; name = Release; };
		C4 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = dev.ycode.skprobe.tests; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/StoreProbe.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/StoreProbe"; BUNDLE_LOADER = "$(TEST_HOST)"; }; name = Debug; };
		C5 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = dev.ycode.skprobe.tests; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/StoreProbe.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/StoreProbe"; BUNDLE_LOADER = "$(TEST_HOST)"; }; name = Release; };
		L0 = {isa = XCConfigurationList; buildConfigurations = (C0, C1, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		L1 = {isa = XCConfigurationList; buildConfigurations = (C2, C3, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		L2 = {isa = XCConfigurationList; buildConfigurations = (C4, C5, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
	};
	rootObject = P0;
}
'''

SCHEME = '''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2700"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "T1"
               BuildableName = "StoreProbe.app"
               BlueprintName = "StoreProbe"
               ReferencedContainer = "container:SKProj.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "T2"
               BuildableName = "StoreProbeTests.xctest"
               BlueprintName = "StoreProbeTests"
               ReferencedContainer = "container:SKProj.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
@TREF@   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "T1"
            BuildableName = "StoreProbe.app"
            BlueprintName = "StoreProbe"
            ReferencedContainer = "container:SKProj.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
      <CommandLineArguments>
         <CommandLineArgument
            argument = "-phase products -session 0"
            isEnabled = "YES">
         </CommandLineArgument>
      </CommandLineArguments>
      <EnvironmentVariables>
         <EnvironmentVariable
            key = "DYLD_FRAMEWORK_PATH"
            value = "@FW@"
            isEnabled = "YES">
         </EnvironmentVariable>
      </EnvironmentVariables>
      <StoreKitConfigurationFileReference
         identifier = "@REF@">
      </StoreKitConfigurationFileReference>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''

if __name__ == "__main__":
    main()
