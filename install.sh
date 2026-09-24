#!/bin/zsh
set -eu

# Resolve the repo root from this script's own location. Without this, the
# relative paths below (JXRouter.xcodeproj, and the pbxproj grep in step 3b)
# only resolve when the cwd happens to BE the repo root -- invoking the
# installer by absolute path from anywhere else died with:
#   xcodebuild: error: 'JXRouter.xcodeproj' does not exist.
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "==========================================="
echo " Installing JXProxy"
echo "==========================================="

# Configuration
JXPROXY_PORT="${JXPROXY_PORT:-5255}"
JXPROXY_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN:-jxproxy}"
LOCAL_BIN="${HOME}/.local/bin"
APP_NAME="JXRouter"

# Default auth token (documented in README). Override with JXPROXY_AUTH_TOKEN to customize.

# Check for Xcode CLI tools
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "Error: xcodebuild not found. Please run 'xcode-select --install'"
    exit 1
fi

# Preflight: the Xcode project must sit next to this script. ROOT is resolved
# from $0 above, so this holds no matter which directory invoked us.
if [ ! -d "$ROOT/JXRouter.xcodeproj" ]; then
    echo "Error: $ROOT/JXRouter.xcodeproj not found." >&2
    echo "   install.sh must live next to JXRouter.xcodeproj in the repo." >&2
    exit 1
fi

# Pre-flight check: hardcoded ANTHROPIC_DEFAULT_* models in shell configs
# force Claude Code to bypass JXProxy's tier routing.
CONFLICT_FILES=""
for f in "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    if [ -f "$f" ] && grep -qE 'ANTHROPIC_DEFAULT_(OPUS|SONNET|HAIKU)_MODEL' "$f" 2>/dev/null; then
        CONFLICT_FILES="$CONFLICT_FILES $f"
    fi
done
if [ -n "$CONFLICT_FILES" ]; then
    echo ""
    echo "⚠️  WARNING: Hardcoded ANTHROPIC_DEFAULT_* model variables detected in:"
    echo "   $CONFLICT_FILES"
    echo "   These override Claude's model selection and can break JXProxy's tier routing."
    echo "   JXProxy installs a protective \`claude\` alias that neutralises them, and the app"
    echo "   also neutralises them via ~/.claude/settings.json while running - but for best"
    echo "   results consider deleting the ANTHROPIC_DEFAULT_* lines from those files."
    echo ""
fi

# Where the Release build lands. Override with JX_BUILD_ROOT=/somewhere.
BUILD_ROOT="${JX_BUILD_ROOT:-/tmp/JXRouterBuild}"

# Optional: install a bundle you built yourself instead of building here.
#   JX_APP_BUNDLE=/path/to/JXRouter.app ./install.sh
# It must be a RELEASE build: a Debug build carries JXRouter.debug.dylib and
# __preview.dylib and is rejected in step 4. In the Xcode IDE the Run action
# defaults to Debug, so use Product > Build For > Running, or set the scheme's
# Run > Build Configuration to Release.
APP_BUNDLE="${JX_APP_BUNDLE:-$BUILD_ROOT/Release/JXRouter.app}"

echo ""
echo "1. Cleaning previous builds..."
rm -rf "$BUILD_ROOT" 2>/dev/null

echo ""
if [ -n "${JX_APP_BUNDLE:-}" ]; then
    echo "3. Using prebuilt bundle: $APP_BUNDLE"
    if [ ! -d "$APP_BUNDLE" ]; then
        echo "Error: JX_APP_BUNDLE does not exist: $APP_BUNDLE" >&2
        exit 1
    fi
else
    echo "3. Building JXProxy (universal: Apple Silicon + Intel)..."
    # ARCHS="arm64 x86_64" + ONLY_ACTIVE_ARCH=NO produces a universal binary so
    # the same build runs on Apple Silicon AND Intel Macs. A pure Swift/AppKit
    # app, so the two slices are byte-for-byte the same code.
    # `if ! cmd` rather than `cmd; if [ $? -ne 0 ]`: under `set -e` a bare
    # failing command aborts the script before the check, so the "Build failed"
    # message never printed and the real error was all you saw.
    mkdir -p "$BUILD_ROOT"
    BUILD_LOG="$BUILD_ROOT/xcodebuild.log"
    # JX_SWIFT_FLAGS is an opt-in escape hatch for sandboxed or CI builds that
    # cannot spawn Xcode's Swift macro plugin server. Symptoms without it:
    #   external macro implementation type 'ObservationMacros.ObservableMacro'
    #   could not be found for macro 'Observable()'
    #   sandbox-exec: sandbox_apply: Operation not permitted
    # Use it as:  JX_SWIFT_FLAGS="-disable-sandbox" ./install.sh
    # Leave unset for a normal local build -- it is NOT needed on a desktop.
    EXTRA_FLAGS=()
    if [ -n "${JX_SWIFT_FLAGS:-}" ]; then
        EXTRA_FLAGS=("OTHER_SWIFT_FLAGS=${JX_SWIFT_FLAGS}")
    fi

    run_build() {
        xcodebuild -project "$ROOT/JXRouter.xcodeproj" -scheme JXRouter \
            -configuration Release \
            ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
            SYMROOT="$BUILD_ROOT" "$@" > "$BUILD_LOG" 2>&1
    }

    if ! run_build "${EXTRA_FLAGS[@]}"; then
        # The Swift compiler spawns its macro plugin server through sandbox-exec.
        # Under an agent or CI harness that refuses the nested sandbox_apply,
        # EVERY @Observable type fails to expand with:
        #   sandbox-exec: sandbox_apply: Operation not permitted
        #   external macro implementation type 'ObservationMacros.ObservableMacro'
        #   could not be found for macro 'Observable()'
        # That is the environment, not the source, so retry once with the
        # compiler's plugin sandbox disabled instead of making the user find
        # JX_SWIFT_FLAGS themselves. A normal desktop build never gets here.
        if [ -z "${JX_SWIFT_FLAGS:-}" ] \
            && grep -qE "sandbox_apply|ObservableMacro" "$BUILD_LOG" 2>/dev/null; then
            echo "   Build hit the Swift macro sandbox limit — retrying with -disable-sandbox..."
            if run_build OTHER_SWIFT_FLAGS="-disable-sandbox"; then
                echo "   Retry succeeded (build was sandbox-limited, not broken)."
            else
                echo "Build failed! Last 40 lines of $BUILD_LOG:" >&2
                tail -40 "$BUILD_LOG" >&2
                exit 1
            fi
        else
            echo "Build failed! Last 40 lines of $BUILD_LOG:" >&2
            tail -40 "$BUILD_LOG" >&2
            exit 1
        fi
    fi
fi

echo ""
echo "3b. Bundling agent resources..."
RESOURCES_SRC="$ROOT/JXRouter/Resources"
RESOURCES_DST="$APP_BUNDLE/Contents/Resources"

if [ -d "$RESOURCES_SRC" ]; then
    [ -f "$RESOURCES_SRC/AGENTS.md" ] && cp "$RESOURCES_SRC/AGENTS.md" "$RESOURCES_DST/AGENTS.md"
    mkdir -p "$RESOURCES_DST/skills"
    if [ -d "$RESOURCES_SRC/skills" ] && [ -n "$(ls -A "$RESOURCES_SRC/skills" 2>/dev/null)" ]; then
        cp -R "$RESOURCES_SRC/skills/." "$RESOURCES_DST/skills/" 2>/dev/null || true
        echo "   Bundled AGENTS.md + skill SKILL.md files"
    else
        echo "   Bundled AGENTS.md"
    fi
else
    echo "   WARNING: Resources/ directory not found at $RESOURCES_SRC"
fi


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

# Bundle the llama.cpp runtime so the built-in GGUF loader needs no setup.
stage_llama_cpp "$APP_BUNDLE"

# Bundling resources AFTER Xcode signed the bundle invalidates its
# code-signature seal ("a sealed resource is missing or invalid") — but only
# when the bundled resources actually changed. Re-sign ONLY when the seal no
# longer verifies, so reinstalls of identical content keep the previous
# signature: the one-time Keychain "Always Allow" grant (bound to the
# code-signature identity) stays valid across reinstalls instead of forcing a
# new permission prompt every time.
SIGN_IDENTITY=$(grep -m1 'CODE_SIGN_IDENTITY =' "$ROOT/JXRouter.xcodeproj/project.pbxproj" | sed -E 's/.*= "?([^";]+)"?;.*/\1/')
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="-"
fi
if codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
    echo "   Bundle signature intact — skipping re-sign (Keychain access grant stays valid)"
else
    echo "   Re-signing bundle with identity: $SIGN_IDENTITY"
    if ! codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"; then
        echo "   Warning: identity not found — falling back to ad-hoc signature"
        codesign --force --deep --sign - "$APP_BUNDLE"
    fi
fi

echo ""
echo "4. Deploying to /Applications..."

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: App bundle not found at $APP_BUNDLE"
    exit 1
fi

# Remove existing app if present.
#
# The removal is VERIFIED, because `cp -R` merges INTO an existing directory
# rather than replacing it: if the rm fails, the copy lands inside the stale
# bundle and anything already sitting in its root survives. That is how a
# stray root symlink got sealed into a supposedly fresh install and failed
# the codesign check below with "unsealed contents present in the bundle root".
killall JXRouter 2>/dev/null || true
rm -rf "/Applications/JXRouter.app" 2>/dev/null || true
rm -rf "/Applications/JXProxy.app" 2>/dev/null || true
if [ -e "/Applications/JXRouter.app" ]; then
    echo "Error: could not remove the existing /Applications/JXRouter.app." >&2
    echo "   Quit JXRouter, delete the bundle manually, then re-run this script." >&2
    exit 1
fi

# Copy new build
cp -R "$APP_BUNDLE" /Applications/

# Strip stray extended attributes on the deployed bundle only (never the repo)
xattr -cr "/Applications/JXRouter.app" 2>/dev/null || true

# A bundle root contains Contents/ and nothing else. Anything else here is
# "unsealed contents present in the bundle root" and invalidates the
# signature, so catch it at the point it is created rather than at verify time.
STRAY=$(find "/Applications/JXRouter.app" -maxdepth 1 -mindepth 1 ! -name Contents 2>/dev/null || true)
if [ -n "$STRAY" ]; then
    echo "Error: stray items in the bundle root:" >&2
    echo "$STRAY" >&2
    echo "   A bundle root must contain only Contents/. Remove the items above and re-run." >&2
    exit 1
fi

# A Release build must not contain debug dylibs; fail loudly if it does
if find "/Applications/JXRouter.app" \( -name '*.debug.dylib' -o -name '*__preview.dylib' \) -print -quit | grep -q .; then
    echo "Error: debug dylibs found in /Applications/JXRouter.app (stale debug build artifacts)." >&2
    exit 1
fi

# Never ad-hoc re-sign: cp -R preserves the Xcode-produced signature.
# Fail loudly if the copy invalidated it.
if ! codesign --verify --deep --strict "/Applications/JXRouter.app"; then
    echo "Error: code signature verification failed for /Applications/JXRouter.app." >&2
    echo "   The copy invalidated the Xcode-produced signature; re-run the build." >&2
    exit 1
fi

echo ""
echo "5. Installing CLI launcher scripts..."

mkdir -p "$LOCAL_BIN"

# jxclaude - Launcher for Claude Code through JXProxy
cat > "$LOCAL_BIN/jxclaude" << 'LAUNCHER'
#!/bin/bash
# JXProxy launcher for Claude Code
# Sets the environment variables needed to route through JXProxy
# Usage: jxclaude [args...]

JXPROXY_PORT="${JXPROXY_PORT:-5255}"
JXPROXY_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN:-jxproxy}"

export ANTHROPIC_BASE_URL="http://127.0.0.1:${JXPROXY_PORT}"
export ANTHROPIC_API_KEY="${JXPROXY_AUTH_TOKEN}"
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=190000
export DISABLE_AUTOUPDATER=1
export DISABLE_FEEDBACK_COMMAND=1
export DISABLE_ERROR_REPORTING=1

echo "🚀 JXProxy: Launching Claude Code on port ${JXPROXY_PORT}..."
echo "   ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}"
echo ""

# Find the real claude binary
REAL_PATH=$(command -v claude 2>/dev/null || true)
if [ -z "$REAL_PATH" ]; then
    # Check common paths
    for p in /opt/homebrew/bin/claude "$HOME/.npm-global/bin/claude" /usr/local/bin/claude; do
        if [ -x "$p" ]; then
            REAL_PATH="$p"
            break
        fi
    done
fi

if [ -z "$REAL_PATH" ]; then
    echo "❌ Error: Claude Code not found on PATH."
    echo "   Install it first: npm install -g @anthropic-ai/claude-code"
    exit 1
fi

exec "$REAL_PATH" "$@"
LAUNCHER
chmod +x "$LOCAL_BIN/jxclaude"

# jxcodex - Launcher for Codex through JXProxy
cat > "$LOCAL_BIN/jxcodex" << 'LAUNCHER'
#!/bin/bash
# JXProxy launcher for Codex CLI
# Sets the environment variables needed to route through JXProxy
# Usage: jxcodex [args...]

JXPROXY_PORT="${JXPROXY_PORT:-5255}"
JXPROXY_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN:-jxproxy}"

export OPENAI_BASE_URL="http://127.0.0.1:${JXPROXY_PORT}/v1"
export OPENAI_API_KEY="${JXPROXY_AUTH_TOKEN}"
export CODEX_BASE_URL="http://127.0.0.1:${JXPROXY_PORT}/v1"
export CODEX_API_KEY="${JXPROXY_AUTH_TOKEN}"

echo "🚀 JXProxy: Launching Codex CLI on port ${JXPROXY_PORT}..."
echo "   OPENAI_BASE_URL=${OPENAI_BASE_URL}"
echo ""

# Find the real codex binary
REAL_PATH=$(command -v codex 2>/dev/null || true)
if [ -z "$REAL_PATH" ]; then
    echo "❌ Error: Codex CLI not found on PATH."
    echo "   Install it first from: https://chatgpt.com/codex"
    exit 1
fi

exec "$REAL_PATH" "$@"
LAUNCHER
chmod +x "$LOCAL_BIN/jxcodex"

# jxpi - Launcher for Pi Coding Agent through JXProxy
cat > "$LOCAL_BIN/jxpi" << 'LAUNCHER'
#!/bin/bash
# JXProxy launcher for Pi Coding Agent
# Sets the environment variables needed to route through JXProxy
# Usage: jxpi [args...]

JXPROXY_PORT="${JXPROXY_PORT:-5255}"
JXPROXY_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN:-jxproxy}"

export OPENAI_BASE_URL="http://127.0.0.1:${JXPROXY_PORT}/v1"
export OPENAI_API_KEY="${JXPROXY_AUTH_TOKEN}"

echo "🚀 JXProxy: Launching Pi Coding Agent on port ${JXPROXY_PORT}..."
echo "   OPENAI_BASE_URL=${OPENAI_BASE_URL}"
echo ""

# Find the real pi binary
REAL_PATH=$(command -v pi 2>/dev/null || true)
if [ -z "$REAL_PATH" ]; then
    echo "❌ Error: Pi Coding Agent not found on PATH."
    echo "   Install it first: curl -fsSL https://pi.dev/install.sh | sh"
    exit 1
fi

exec "$REAL_PATH" "$@"
LAUNCHER
chmod +x "$LOCAL_BIN/jxpi"

# jxserver - Start the JXProxy server in background with nohup
cat > "$LOCAL_BIN/jxserver" << 'LAUNCHER'
#!/bin/bash
# JXProxy server launcher (background with nohup)
# Opens the JXRouter macOS app (which runs the proxy server)
# Usage: jxserver [--headless]

if [ "$1" = "--headless" ]; then
    echo "🚀 JXProxy: Starting proxy server in background (headless)..."
    # Arm auto-start first: `open` alone only brings the menu-bar app up, it
    # does not start the listener, so this used to leave the proxy down until
    # someone clicked the icon.
    defaults write com.marshaljlee.jxrouter autoStartProxy -bool true 2>/dev/null || true
    nohup open "/Applications/JXRouter.app" > /dev/null 2>&1 &
    echo "   PID: $!"
else
    echo "🚀 JXProxy: Starting proxy server..."
    defaults write com.marshaljlee.jxrouter autoStartProxy -bool true 2>/dev/null || true
    open "/Applications/JXRouter.app"
fi
echo "   Default proxy port: ${JXPROXY_PORT:-5255}"
echo "   Auth token: ${JXPROXY_AUTH_TOKEN:-jxproxy}"
echo ""
if pgrep -x JXRouter >/dev/null 2>&1; then
    echo "   JXRouter is running — control it from the menu bar icon."
else
    echo "   WARN: JXRouter is not running; check ~/.jxrouter/logs/engine.log" >&2
fi
echo ""
echo "   To use Claude Code via JXProxy:"
echo "     jxclaude"
echo ""
echo "   To use Pi via JXProxy:"
echo "     jxpi"
echo ""
echo "   To use Codex via JXProxy:"
echo "     jxcodex"
LAUNCHER
chmod +x "$LOCAL_BIN/jxserver"

echo ""
echo "6. Updating PATH in shell config..."

add_to_path() {
    local shell_config="$1"
    if [ -f "$shell_config" ]; then
        if ! grep -q "JXPROXY" "$shell_config" 2>/dev/null; then
            echo "" >> "$shell_config"
            echo "# JXProxy Configuration" >> "$shell_config"
            echo "export JXPROXY_PORT=\"${JXPROXY_PORT}\"" >> "$shell_config"
            echo "export JXPROXY_AUTH_TOKEN=\"${JXPROXY_AUTH_TOKEN}\"" >> "$shell_config"
            echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$shell_config"
            echo "" >> "$shell_config"
            echo "# JXProxy protective alias - neutralises shell-level ANTHROPIC_DEFAULT_* model overrides" >> "$shell_config"
            echo "# that would otherwise bypass JXProxy's tier routing. Plain \`claude\` keeps working." >> "$shell_config"
            echo "alias claude=\"unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL && claude\"" >> "$shell_config"
            echo "# End JXProxy" >> "$shell_config"
            echo "Added JXProxy configuration to $shell_config"
        fi
    fi
}

add_to_path "$HOME/.zshrc"
add_to_path "$HOME/.bashrc"

# Also add to PATH for current session
export PATH="$LOCAL_BIN:$PATH"

echo ""
echo "7. Creating desktop shortcut..."

# `ln -s TARGET DEST` creates the link INSIDE DEST when DEST already resolves
# to a directory -- including a symlink that points at one, and even without
# -f. Because an earlier install left
#   ~/Desktop/JXProxy.app -> /Applications/JXRouter.app
# every later run followed it and created
#   /Applications/JXRouter.app/JXRouter.app -> /Applications/JXRouter.app
# junk inside the app bundle, which codesign rejects with "unsealed contents
# present in the bundle root". `-n` stops ln dereferencing DEST, so the link is
# replaced instead of nested. Measured: `ln -sfn` leaves the target empty,
# while plain `ln -s` creates target/target.
ln -sfn "/Applications/JXRouter.app" "$HOME/Desktop/JXProxy.app" 2>/dev/null || true

echo ""
echo "8. Verifying installation..."

INSTALLED="/Applications/JXRouter.app"
VERIFY_FAIL=0

if [ ! -d "$INSTALLED" ]; then
    echo "   FAIL: $INSTALLED is missing" >&2
    VERIFY_FAIL=1
else
    echo "   app:       $INSTALLED"
    echo "   version:   $(defaults read "$INSTALLED/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
    echo "   bundle id: $(defaults read "$INSTALLED/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo '?')"
    echo "   archs:     $(lipo -archs "$INSTALLED/Contents/MacOS/JXRouter" 2>/dev/null || echo '?')"

    # Name the cause before the opaque codesign complaint. A bundle root holds
    # Contents/ and nothing else; a stray entry there is reported by codesign
    # only as "unsealed contents present in the bundle root", which never says
    # which item is at fault.
    STRAY_ROOT=$(find "$INSTALLED" -maxdepth 1 -mindepth 1 ! -name Contents 2>/dev/null || true)
    if [ -n "$STRAY_ROOT" ]; then
        echo "   FAIL: stray items in the bundle root (unsealed contents):" >&2
        echo "$STRAY_ROOT" >&2
        echo "         A bundle root must contain only Contents/. Remove them and re-run." >&2
        VERIFY_FAIL=1
    fi

    if codesign --verify --deep --strict "$INSTALLED" 2>/dev/null; then
        echo "   signature: valid"
    else
        echo "   FAIL: code signature does not verify" >&2
        VERIFY_FAIL=1
    fi

    if [ -f "$INSTALLED/Contents/Frameworks/libjxllama.dylib" ]; then
        echo "   engine:    in-process libjxllama.dylib embedded"
        # A stock-upstream engine cannot load the Prism ternary formats
        # (GGML_TYPE_PQ2_0 142 / PTQ1_0 143). That is invisible at build time
        # and shows up much later as "the app does not detect my model", so
        # surface it here, where the engine actually ships.
        TQ=$(grep -a -c PQ2_0 "$INSTALLED/Contents/Frameworks/libjxllama.dylib" 2>/dev/null || true)
        case "$TQ" in ''|*[!0-9]*) TQ=0 ;; esac
        if [ "$TQ" -gt 0 ]; then
            echo "   ternary:   PQ2_0/PTQ1_0 supported"
        else
            echo "   WARN: engine has no PQ2_0/PTQ1_0 support - Ternary-Bonsai GGUFs will not load" >&2
            echo "         rebuild with: LLAMA_SRC=\$HOME/.prism/llama.cpp LlamaEngine/build.sh" >&2
        fi
    else
        echo "   WARN: in-process engine (Frameworks/libjxllama.dylib) is missing" >&2
    fi

    if [ -x "$INSTALLED/Contents/Resources/llama-cpp/llama-server" ]; then
        echo "   runtime:   llama.cpp bundled"
        # llama-server is a SECOND, independent engine from libjxllama.dylib:
        # it serves only when the in-process engine is disabled or unavailable.
        # install.sh stages it from the runtime JXRouter downloaded, or from the
        # official ggml-org release -- both stock upstream, so neither carries
        # the Prism ternary formats. Say so rather than let it fail silently.
        SRV=0
        if [ -d "$INSTALLED/Contents/Resources/llama-cpp" ]; then
            if grep -a -r -l -q PQ2_0 "$INSTALLED/Contents/Resources/llama-cpp" 2>/dev/null; then
                SRV=1
            fi
        fi
        if [ "$SRV" -gt 0 ]; then
            echo "   ternary:   llama-server supports PQ2_0/PTQ1_0"
        else
            echo "   note:      bundled llama-server is stock upstream (no PQ2_0/PTQ1_0)"
            echo "              harmless while the in-process engine is enabled (default on)"
        fi
    else
        echo "   runtime:   not bundled (the app downloads it on first use)"
    fi
fi

if [ "$VERIFY_FAIL" -ne 0 ]; then
    echo "" >&2
    echo "Installation did NOT complete cleanly -- see FAIL lines above." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 9. Start it. One command, end to end.
#
# A build that is installed but not running is not an install. This script
# previously stopped at "you can launch it by running open ...", leaving the
# user to launch the app AND then click the menu-bar icon -> Start. Three
# steps -- and an easy way to believe a rebuild took effect while the OLD
# binary was still the one running.
#
# Two things make the launch automatic:
#   - killall first. `open` on an already-running app just activates the old
#     process, so a rebuild silently keeps running the previous build.
#   - autoStartProxy=true. The app reads this in applicationDidFinishLaunching
#     and calls startProxy() itself, so no menu-bar click is needed.
# Set JX_NO_AUTOSTART=1 to install without launching (CI, or a manual start).
# ---------------------------------------------------------------------------
echo ""
if [ -n "${JX_NO_AUTOSTART:-}" ]; then
    echo "9. Skipping auto-start (JX_NO_AUTOSTART is set)."
    echo "   Start it later with: jxserver"
else
    echo "9. Starting JXProxy..."

    # Replace any running instance so the binary that ends up running IS the
    # one just installed.
    if pgrep -x JXRouter >/dev/null 2>&1; then
        killall JXRouter 2>/dev/null || true
        # Wait for the process (and its port) to actually go away before
        # relaunching, otherwise the new instance can lose the race for the
        # port and come up with routing disabled.
        for _ in $(seq 1 40); do
            pgrep -x JXRouter >/dev/null 2>&1 || break
            sleep 0.25
        done
        echo "   stopped the previous instance"
    fi

    # Arm auto-start BEFORE launching, so the very first launch already has it.
    # Not sandboxed, so UserDefaults.standard is the plain bundle-id domain.
    defaults write com.marshaljlee.jxrouter autoStartProxy -bool true 2>/dev/null || true

    open "/Applications/JXRouter.app" 2>/dev/null || true

    # Poll until the proxy actually answers. Launch is asynchronous and the
    # in-process engine takes a moment to bind, so a bare `open` proves
    # nothing -- this is the difference between "started" and "running".
    PROXY_UP=0
    for _ in $(seq 1 60); do
        if curl -fsS -m 2 -o /dev/null \
            -H "Authorization: Bearer ${JXPROXY_AUTH_TOKEN}" \
            "http://127.0.0.1:${JXPROXY_PORT}/v1/models" 2>/dev/null; then
            PROXY_UP=1
            break
        fi
        sleep 0.5
    done

    if [ "$PROXY_UP" -eq 1 ]; then
        echo "   proxy:     listening on http://127.0.0.1:${JXPROXY_PORT}"

        # /v1/models answers as soon as the listener is bound, so it proves the
        # proxy is up but NOT that it can serve: with no model loaded it still
        # returns 200 while every real request comes back 503 "All providers
        # failed". Ask for a single token to tell "reachable" from "running" --
        # otherwise this script prints "Installation Complete" over a proxy that
        # fails every call, and the failure only shows up at first use.
        MODEL_CODE=$(curl -s -m 20 -o /dev/null -w '%{http_code}' \
            -X POST "http://127.0.0.1:${JXPROXY_PORT}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${JXPROXY_AUTH_TOKEN}" \
            -d '{"model":"local","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
            2>/dev/null || true)
        MODEL_CODE="${MODEL_CODE:-000}"
        case "$MODEL_CODE" in
            2*)
                echo "   model:     serving"
                ;;
            *)
                echo "   WARN: the proxy is up but a test completion returned HTTP ${MODEL_CODE}." >&2
                echo "         No model is loaded, so every request will fail until you open" >&2
                echo "         the menu-bar icon and press Start." >&2
                ;;
        esac
    else
        echo "   WARN: the app launched but the proxy is not answering on port ${JXPROXY_PORT} yet." >&2
        echo "         Open the menu-bar icon and press Start." >&2
        echo "         If it keeps failing, check: ~/.jxrouter/logs/engine.log" >&2
    fi
fi

echo ""
echo "==========================================="
echo " ✅ JXProxy Installation Complete!"
echo "==========================================="
echo ""
echo " JXProxy is now installed in /Applications/JXRouter.app"
if [ -z "${JX_NO_AUTOSTART:-}" ]; then
    echo " and running on port ${JXPROXY_PORT}."
fi
echo ""
echo " CLI Commands:"
echo "   jxserver         Open JXProxy from terminal"
echo "   jxclaude         Launch Claude Code through JXProxy"
echo "   jxcodex          Launch Codex through JXProxy"
echo "   jxpi             Launch Pi Coding Agent through JXProxy"
echo ""
echo " Default port: ${JXPROXY_PORT}"
echo " Auth token:   ${JXPROXY_AUTH_TOKEN}"
echo ""
echo " For VS Code Claude Code extension, add to settings.json:"
echo '   "claudeCode.environmentVariables": ['
echo '     { "name": "ANTHROPIC_BASE_URL", "value": "http://127.0.0.1:'${JXPROXY_PORT}'" },'
echo '     { "name": "ANTHROPIC_API_KEY", "value": "'${JXPROXY_AUTH_TOKEN}'" },'
echo '     { "name": "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY", "value": "1" }'
echo '   ]'
echo ""
