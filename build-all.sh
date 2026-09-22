#!/bin/bash
# build-all.sh — one command to build every platform into dist/.
#
# Produces:
#   dist/JXRouter.app                  universal macOS app (x86_64 + arm64);
#                                      if dist/ is iCloud-synced the .app is
#                                      dropped and only the zip is kept (see below)
#   dist/JXRouter-macOS-universal.zip  the macOS app, zipped — always produced,
#                                      immune to iCloud metadata, use this for sharing
#   dist/JXProxyMobile-debug.apk       Android debug APK (installable)
#   dist/JXProxyMobile-release-unsigned.apk   Android release APK (sign before shipping)
#   dist/JXProxyMobile-simulator.app   iOS build for the Simulator
#   dist/JXProxyMobile-device.app      iOS Release build (re-sign with a dev team for devices)
#
# Usage:
#   ./build-all.sh          build everything
#   ./build-all.sh macos    only the macOS app
#   ./build-all.sh android  only the Android APKs
#   ./build-all.sh ios      only the iOS builds
#
# Requirements: Xcode (macOS + iOS SDKs), Android SDK (see android/local.properties
# or $ANDROID_HOME), and a JDK 17+ (auto-detected, override with $JAVA_HOME).

set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
REQUESTED="${1:-all}"

echo "==========================================="
echo " JXProxy build-all"
echo "==========================================="
echo ""

mkdir -p "$DIST"

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

fail() {
    echo "❌ $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Bundle the llama.cpp runtime (llama-server) into the app so the built-in GGUF
# loader works with zero setup. Prefers the copy JXRouter already installed or
# updated; otherwise downloads the newest official macOS build for this Mac.
# Set JXROUTER_SKIP_LLAMA=1 to skip.
# ---------------------------------------------------------------------------
stage_llama_cpp() {
    local APP_BUNDLE="$1"
    local RES="$APP_BUNDLE/Contents/Resources/llama-cpp"

    if [ -n "${JXROUTER_SKIP_LLAMA:-}" ]; then
        echo "   Skipping llama.cpp bundling (JXROUTER_SKIP_LLAMA is set)"
        return 0
    fi

    local MANAGED="$HOME/Library/Application Support/JXRouter/llama-cpp/current"
    if [ -x "$MANAGED/llama-server" ]; then
        mkdir -p "$RES"
        cp -R "$MANAGED"/. "$RES"/ 2>/dev/null || true
        xattr -dr com.apple.quarantine "$RES" 2>/dev/null || true
        echo "   Bundled llama.cpp from the runtime installed by JXRouter"
        return 0
    fi

    command -v curl >/dev/null 2>&1 || { echo "   Warning: curl not found - skipping llama.cpp bundle"; return 0; }

    local SUFFIX="arm64"
    [ "$(uname -m)" = "arm64" ] || SUFFIX="x64"
    local TAG
    TAG=$(curl -sL --max-time 30 "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=20" \
          | grep -o '"tag_name": *"b[0-9]*"' | head -1 | grep -o 'b[0-9]*')
    if [ -z "$TAG" ]; then
        echo "   Warning: could not resolve a llama.cpp release - the app downloads it on first use"
        return 0
    fi

    local TMP="/tmp/jxrouter-llama-$TAG"
    local ASSET="llama-${TAG}-bin-macos-${SUFFIX}.tar.gz"
    rm -rf "$TMP"; mkdir -p "$TMP"
    echo "   Downloading llama.cpp $TAG (macOS $SUFFIX)..."
    if ! curl -sL --max-time 900 -o "$TMP/$ASSET" \
         "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/$ASSET"; then
        echo "   Warning: llama.cpp download failed - the app downloads it on first use"
        return 0
    fi
    rm -rf "$RES"; mkdir -p "$RES"
    if ! tar -xzf "$TMP/$ASSET" -C "$RES" --strip-components=1; then
        echo "   Warning: llama.cpp extraction failed - skipping"
        rm -rf "$RES"
        return 0
    fi
    xattr -dr com.apple.quarantine "$RES" 2>/dev/null || true
    find "$RES" -maxdepth 1 \( -name 'llama-*' -o -name '*.dylib' \) -exec chmod 755 {} + 2>/dev/null || true
    echo "   Bundled llama.cpp $TAG into the app"
}

# ---------------------------------------------------------------------------
# macOS — universal (Apple Silicon + Intel)
# ---------------------------------------------------------------------------
build_macos() {
    echo "=== [1/3] macOS (universal: x86_64 + arm64) ==="
    command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found — run 'xcode-select --install'"

    rm -rf /tmp/JXRouterBuildAll
    xcodebuild -project "$ROOT/JXRouter.xcodeproj" -scheme JXRouter -configuration Release \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
        SYMROOT="/tmp/JXRouterBuildAll" > /dev/null || fail "macOS build failed"

    APP_BUNDLE="/tmp/JXRouterBuildAll/Release/JXRouter.app"
    [ -d "$APP_BUNDLE" ] || fail "macOS app bundle not found at $APP_BUNDLE"

    # Bundle agent resources the same way install.sh does
    RESOURCES_SRC="$ROOT/JXRouter/Resources"
    if [ -d "$RESOURCES_SRC" ]; then
        cp "$RESOURCES_SRC/AGENTS.md" "$APP_BUNDLE/Contents/Resources/AGENTS.md" 2>/dev/null || true
        mkdir -p "$APP_BUNDLE/Contents/Resources/skills"
        cp -R "$RESOURCES_SRC/skills/"* "$APP_BUNDLE/Contents/Resources/skills/" 2>/dev/null || true
        echo "   Bundled AGENTS.md + skills"
    fi

    # Bundle the llama.cpp runtime so the built-in GGUF loader needs no setup.
    stage_llama_cpp "$APP_BUNDLE"

    # Re-sign only if the resource copy broke the seal (keeps the Keychain
    # "Always Allow" grant stable across identical rebuilds)
    SIGN_IDENTITY=$(grep -m1 'CODE_SIGN_IDENTITY =' "$ROOT/JXRouter.xcodeproj/project.pbxproj" | sed -E 's/.*= "?([^";]+)"?;.*/\1/')
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="-"
    if codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
        echo "   Bundle signature intact — skipping re-sign"
    else
        echo "   Re-signing bundle with identity: $SIGN_IDENTITY"
        if ! codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE" 2>/dev/null; then
            echo "   Warning: identity not found — falling back to ad-hoc signature"
            codesign --force --deep --sign - "$APP_BUNDLE"
        fi
    fi
    codesign --verify --deep --strict "$APP_BUNDLE" || fail "macOS code signature invalid"

    rm -rf "$DIST/JXRouter.app" "$DIST/JXRouter-macOS-universal.zip"
    cp -R "$APP_BUNDLE" "$DIST/JXRouter.app"
    # Strip iCloud/network-drive metadata (resource forks, provenance) that
    # would otherwise break the code-signature seal of the copied bundle.
    xattr -cr "$DIST/JXRouter.app" 2>/dev/null || true
    (cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent JXRouter.app JXRouter-macOS-universal.zip)
    if codesign --verify --deep --strict "$DIST/JXRouter.app" 2>/dev/null; then
        echo "   → dist/JXRouter.app + dist/JXRouter-macOS-universal.zip"
    else
        # dist/ is inside an iCloud/network-synced folder: macOS re-adds
        # com.apple.FinderInfo to the .app after the copy, breaking its seal.
        # The zip is a single file and immune, so it becomes the artifact.
        rm -rf "$DIST/JXRouter.app"
        echo "   ⚠️  dist/ is iCloud-synced, which re-marks .app bundles and invalidates"
        echo "      their code signature. Kept only the (valid) zip:"
        echo "   → dist/JXRouter-macOS-universal.zip"
        echo "      Unzip it anywhere — the extracted app is signed and verified."
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Android — debug + release APKs
# ---------------------------------------------------------------------------
find_jdk() {
    local candidates=(
        "${JAVA_HOME:-}"
        /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
        /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
        /opt/homebrew/opt/openjdk@11/libexec/openjdk.jdk/Contents/Home
        /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home
    )
    for c in "${candidates[@]}"; do
        if [ -n "$c" ] && [ -x "$c/bin/java" ]; then
            echo "$c"
            return 0
        fi
    done
    /usr/libexec/java_home 2>/dev/null || true
}

build_android() {
    echo "=== [2/3] Android (debug + release APKs) ==="
    JDK="$(find_jdk)"
    [ -n "$JDK" ] && [ -x "$JDK/bin/java" ] || fail "No JDK 17+ found — set JAVA_HOME or install one (brew install openjdk@21)"
    export JAVA_HOME="$JDK"
    echo "   JDK: $JDK"

    # Point Gradle at the Android SDK: android/local.properties if present, else $ANDROID_HOME
    if [ ! -f "$ROOT/android/local.properties" ] && [ -n "${ANDROID_HOME:-}" ]; then
        mkdir -p "$ROOT/android"
        printf 'sdk.dir=%s\n' "$ANDROID_HOME" > "$ROOT/android/local.properties"
    fi

    # Generate the wrapper on first run (so a fresh checkout works out of the box)
    if [ ! -x "$ROOT/android/gradlew" ]; then
        command -v gradle >/dev/null 2>&1 || fail "gradle not installed and no wrapper present — run 'gradle wrapper' in android/ once"
        (cd "$ROOT/android" && gradle wrapper --gradle-version 8.10.2 > /dev/null)
    fi

    (cd "$ROOT/android" && JAVA_HOME="$JDK" ./gradlew --no-daemon assembleDebug assembleRelease) || fail "Android build failed"

    cp "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk" "$DIST/JXProxyMobile-debug.apk"
    cp "$ROOT/android/app/build/outputs/apk/release/app-release-unsigned.apk" "$DIST/JXProxyMobile-release-unsigned.apk"
    echo "   → dist/JXProxyMobile-debug.apk + dist/JXProxyMobile-release-unsigned.apk"
    echo ""
}

# ---------------------------------------------------------------------------
# iOS — simulator + device builds
# ---------------------------------------------------------------------------
build_ios() {
    echo "=== [3/3] iOS (simulator + device) ==="
    command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found"

    rm -rf /tmp/iOSSimBuild /tmp/iOSDeviceBuild

    # Simulator (Debug, no signing needed)
    xcodebuild -project "$ROOT/ios/JXProxyMobile.xcodeproj" -target JXProxyMobile \
        -configuration Debug -sdk iphonesimulator \
        SYMROOT=/tmp/iOSSimBuild CODE_SIGNING_ALLOWED=NO build > /dev/null \
        || fail "iOS simulator build failed"

    # Device (Release, unsigned — re-sign with an Apple Developer team to install)
    xcodebuild -project "$ROOT/ios/JXProxyMobile.xcodeproj" -target JXProxyMobile \
        -configuration Release -sdk iphoneos \
        SYMROOT=/tmp/iOSDeviceBuild CODE_SIGNING_ALLOWED=NO build > /dev/null \
        || fail "iOS device build failed"

    rm -rf "$DIST/JXProxyMobile-simulator.app" "$DIST/JXProxyMobile-device.app"
    cp -R /tmp/iOSSimBuild/Debug-iphonesimulator/JXProxyMobile.app "$DIST/JXProxyMobile-simulator.app"
    cp -R /tmp/iOSDeviceBuild/Release-iphoneos/JXProxyMobile.app "$DIST/JXProxyMobile-device.app"
    codesign --force --sign - "$DIST/JXProxyMobile-device.app" 2>/dev/null || true
    echo "   → dist/JXProxyMobile-simulator.app + dist/JXProxyMobile-device.app"
    echo ""
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
case "$REQUESTED" in
    all)     build_macos; build_android; build_ios ;;
    macos)   build_macos ;;
    android) build_android ;;
    ios)     build_ios ;;
    *)       echo "Usage: $0 [all|macos|android|ios]" >&2; exit 1 ;;
esac

echo "==========================================="
echo " ✅ Build complete — artifacts in $DIST"
echo "==========================================="
echo ""
ls -la "$DIST"
echo ""
if [ -d "$DIST/JXRouter.app" ]; then
    echo "   • macOS:   dist/JXRouter.app (universal) — or install with ./install.sh"
else
    echo "   • macOS:   dist/JXRouter-macOS-universal.zip (universal) — unzip, or install with ./install.sh"
fi
echo "   • Android: dist/JXProxyMobile-debug.apk — installable right away"
echo "              dist/JXProxyMobile-release-unsigned.apk — sign with your keystore"
echo "   • iOS:     dist/JXProxyMobile-simulator.app — for the Simulator"
echo "              dist/JXProxyMobile-device.app — re-sign with a dev team for devices"
