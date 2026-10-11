/// Settings that the build system computes or forces after normal level
/// resolution. They take precedence over everything, including command-line
/// overrides. Each rule here comes from a black-box experiment against the
/// reference Xcode. See `specs/build-settings.md` §4.
public enum DerivedSettings {
    public struct Inputs {
        /// `PBXNativeTarget`, `PBXAggregateTarget`, …, or nil at project level.
        public var targetClass: String?
        public var productType: String?
        /// Platform of the resolved SDK (`MacOSX`, `iPhoneOS`, `iPhoneSimulator`, …).
        public var platform: String?
        /// Filesystem path of the resolved SDK.
        public var sdkPath: String?

        public init(targetClass: String?, productType: String?, platform: String?, sdkPath: String?) {
            self.targetClass = targetClass
            self.productType = productType
            self.platform = platform
            self.sdkPath = sdkPath
        }
    }

    static let testBundleTypes: Set<String> = [
        "com.apple.product-type.bundle.unit-test",
        "com.apple.product-type.bundle.ui-testing",
    ]

    /// Literal values to put above every other level.
    public static func compute(_ s: BuildSettings, _ inputs: Inputs) -> [String: String] {
        var out: [String: String] = [:]

        // SDKROOT is reported as the resolved SDK's path.
        if let path = inputs.sdkPath { out["SDKROOT"] = path }

        let unoptimized = s["GCC_OPTIMIZATION_LEVEL"] == "0" || s["SWIFT_OPTIMIZATION_LEVEL"] == "-Onone"
        out["IS_UNOPTIMIZED_BUILD"] = unoptimized ? "YES" : "NO"

        // Requested previews need an unoptimized Swift build. Without one,
        // previews and their debug dylib are switched off. With one, an
        // ad-hoc-signed product loses the hardened runtime.
        if MacroOperators.isTrue(s["ENABLE_PREVIEWS"]) {
            if unoptimized && !s["SWIFT_VERSION"].isEmpty {
                if s["CODE_SIGN_IDENTITY"] == "-" { out["ENABLE_HARDENED_RUNTIME"] = "NO" }
            } else {
                out["ENABLE_PREVIEWS"] = "NO"
                out["ENABLE_DEBUG_DYLIB"] = "NO"
                out["ENABLE_XOJIT_PREVIEWS"] = "NO"
            }
        }

        // Native targets always search their products' include directory first.
        if inputs.targetClass == "PBXNativeTarget" {
            out["HEADER_SEARCH_PATHS"] = s["BUILT_PRODUCTS_DIR"] + "/include " + s["HEADER_SEARCH_PATHS"]
        }

        if let type = inputs.productType, testBundleTypes.contains(type) {
            // Test bundles load the swift-testing macro plugin.
            let flag = "-plugin-path " + s["TOOLCHAIN_DIR"] + "/usr/lib/swift/host/plugins/testing"
            let existing = s["OTHER_SWIFT_FLAGS"]
            out["OTHER_SWIFT_FLAGS"] = existing.isEmpty ? flag : existing + " " + flag
            // Test bundles for devices always get a dSYM.
            if let platform = inputs.platform, platform != "MacOSX", !platform.hasSuffix("Simulator") {
                out["DEBUG_INFORMATION_FORMAT"] = "dwarf-with-dsym"
            }
        }
        return out
    }
}
