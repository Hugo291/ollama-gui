# Sourced by the build scripts. Sets SDK_ARGS (and SDKROOT) for `swift build`.
#
# Since the macOS 27 SDK, SwiftUI's @State is a macro whose compiler plugin ships with
# Xcode only. With the Command Line Tools alone, build against the newest installed SDK
# that doesn't need it. With Xcode, the default SDK is used.
SDK_ARGS=()
DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEVELOPER_DIR_PATH" == *CommandLineTools* ]]; then
    SWIFTUI_PLUGIN="$(find "$DEVELOPER_DIR_PATH/usr/lib/swift" -name 'libSwiftUIMacros.dylib' 2>/dev/null | head -n 1)"
    if [[ -z "$SWIFTUI_PLUGIN" ]]; then
        CHOSEN_SDK=""
        while IFS= read -r sdk; do
            interface_dir="$sdk/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules"
            if ! grep -rqs "StateMacro" "$interface_dir"; then
                CHOSEN_SDK="$sdk"
            fi
        done < <(ls -d "$DEVELOPER_DIR_PATH"/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -t X -k 2 -V)
        if [[ -n "$CHOSEN_SDK" ]]; then
            export SDKROOT="$CHOSEN_SDK"
            SDK_ARGS=(--sdk "$CHOSEN_SDK")
            echo "▸ Command Line Tools without SwiftUI macros: using $(basename "$CHOSEN_SDK")"
        fi
    fi
fi

# The Command Line Tools don't pass the swift-testing macro plugin to the compiler.
TEST_ARGS=()
TESTING_PLUGINS="$DEVELOPER_DIR_PATH/usr/lib/swift/host/plugins/testing"
if [[ "$DEVELOPER_DIR_PATH" == *CommandLineTools* && -d "$TESTING_PLUGINS" ]]; then
    TEST_ARGS=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS")
fi
