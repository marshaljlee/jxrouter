#!/bin/zsh
set -eu

echo "==========================================="
echo " 🔄 JXProxy Complete Reinstall"
echo "==========================================="
echo ""
echo "This script will:"
echo "  1. Completely remove ALL existing JXProxy files"
echo "  2. Clone the latest version from GitHub"
echo "  3. Build and install fresh"
echo ""

# Ask for confirmation
echo -n "Continue? (y/N): "
read -r CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

REPO_URL="https://github.com/marshaljlee/jxrouter.git"
BUILD_DIR="/tmp/jxproxy-rebuild"

# =============================================================================
# STEP 0: Stop running processes
# =============================================================================
echo ""
echo "⏹  Stopping running JXProxy processes..."
if pgrep -x JXRouter >/dev/null 2>&1; then
    killall JXRouter 2>/dev/null || true
    sleep 1
    echo "   Stopped JXRouter process"
fi
# Kill any lingering launcher scripts
for cmd in jxclaude jxcodex jxpi jxserver; do
    pkill -f "$cmd" 2>/dev/null || true
done

# =============================================================================
# STEP 1: Remove app bundle
# =============================================================================
echo ""
echo "1. Removing app bundle..."
if [ -d "/Applications/JXRouter.app" ]; then
    rm -rf "/Applications/JXRouter.app"
    echo "   Removed /Applications/JXRouter.app"
fi

# =============================================================================
# STEP 2: Remove desktop shortcuts
# =============================================================================
echo ""
echo "2. Removing desktop shortcuts..."
rm -f "$HOME/Desktop/JXProxy.app" 2>/dev/null || true
echo "   Cleaned desktop shortcut"

# =============================================================================
# STEP 3: Remove CLI launcher scripts
# =============================================================================
echo ""
echo "3. Removing CLI launcher scripts..."
LOCAL_BIN="${HOME}/.local/bin"
for cmd in jxclaude jxcodex jxpi jxserver; do
    rm -f "$LOCAL_BIN/$cmd" 2>/dev/null || true
done
echo "   Removed CLI launchers from $LOCAL_BIN"

# =============================================================================
# STEP 4: Clean shell config
# =============================================================================
echo ""
echo "4. Cleaning shell config..."

clean_shell_config() {
    local config="$1"
    if [ -f "$config" ]; then
        local changed=false
        if grep -q "JXPROXY" "$config" 2>/dev/null; then
            sed -i '' '/^# JXProxy Configuration/d' "$config" 2>/dev/null || true
            sed -i '' '/^export JXPROXY_PORT/d' "$config" 2>/dev/null || true
            sed -i '' '/^export JXPROXY_AUTH_TOKEN/d' "$config" 2>/dev/null || true
            # Remove PATH addition lines that reference .local/bin (only ours)
            sed -i '' '/^export PATH=.*local\/bin.*JXPROXY/d' "$config" 2>/dev/null || true
            changed=true
        fi
        if $changed; then
            echo "   Cleaned $config"
        fi
    fi
}

clean_shell_config "$HOME/.zshrc"
clean_shell_config "$HOME/.bashrc"

# =============================================================================
# STEP 5: Clean build artifacts
# =============================================================================
echo ""
echo "5. Cleaning build artifacts..."
rm -rf /tmp/JXRouterBuild 2>/dev/null || true
rm -rf /tmp/jxproxy-hosts.tmp /tmp/jxproxy-pf.conf /tmp/jxproxy-hosts-clean.tmp 2>/dev/null || true
rm -rf "$BUILD_DIR" 2>/dev/null || true
rm -rf Build/ 2>/dev/null || true
echo "   Removed temp files and build artifacts"

# =============================================================================
# STEP 6: Remove Application Support files (CA certs, host certs)
# =============================================================================
echo ""
echo "6. Removing Application Support files..."
JXPROXY_SUPPORT="$HOME/Library/Application Support/JXProxy"
if [ -d "$JXPROXY_SUPPORT" ]; then
    rm -rf "$JXPROXY_SUPPORT"
    echo "   Removed $JXPROXY_SUPPORT (CA certs, host certs)"
fi

# =============================================================================
# STEP 7: Remove error logs
# =============================================================================
echo ""
echo "7. Removing error logs..."
rm -f "$HOME/Library/Logs/jxproxy-error.log" 2>/dev/null || true
echo "   Removed error logs"

# =============================================================================
# STEP 8: Remove FIFO pipe and legacy config
# =============================================================================
echo ""
echo "8. Removing FIFO pipe and legacy config..."
rm -f "$HOME/.jxproxy_bot_commands" 2>/dev/null || true
rm -rf "$HOME/.jxproxy" 2>/dev/null || true
echo "   Cleaned FIFO pipe and legacy config"

# =============================================================================
# STEP 9: Remove DNS hijack + pf anchor (requires admin)
# =============================================================================
echo ""
echo "9. Removing DNS hijack entries (requires admin)..."
echo "   You may be prompted for your password..."

CLEANUP_SCRIPT=""
if grep -q "JXProxy DNS Hijack" /etc/hosts 2>/dev/null; then
    CLEANUP_SCRIPT="$CLEANUP_SCRIPT cp /etc/hosts /etc/hosts.jxproxy.backup; sed -i '' '/# JXProxy DNS Hijack/,/# End JXProxy DNS Hijack/d' /etc/hosts;"
fi
CLEANUP_SCRIPT="$CLEANUP_SCRIPT /sbin/pfctl -a com.apple/250.jxproxy -F all 2>/dev/null || true;"
CLEANUP_SCRIPT="$CLEANUP_SCRIPT /usr/bin/dscacheutil -flushcache 2>/dev/null || true;"
CLEANUP_SCRIPT="$CLEANUP_SCRIPT /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true;"

if [ -n "$CLEANUP_SCRIPT" ]; then
    osascript -e "do shell script \"$CLEANUP_SCRIPT\" with administrator privileges" 2>/dev/null && \
        echo "   Removed DNS hijack and pf anchor" || \
        echo "   ⚠️  DNS cleanup skipped (admin not granted)"
fi

# =============================================================================
# STEP 10: Remove Keychain entries
# =============================================================================
echo ""
echo "10. Removing Keychain entries..."
security delete-generic-password -s "com.jxproxy" -a "OPENAI_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "OPENROUTER_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "OPENCODE_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "ANTHROPIC_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "NVIDIA_NIM_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "DEEPSEEK_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "GEMINI_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "MISTRAL_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "CODESTRAL_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "COHERE_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "GROQ_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "FIREWORKS_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "SAMBANOVA_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "CEREBRAS_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "HUGGINGFACE_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "XAI_API_KEY" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "TELEGRAM_BOT_TOKEN" 2>/dev/null || true
security delete-generic-password -s "com.jxproxy" -a "ADMIN_PASSWORD" 2>/dev/null || true
# Also clean old com.jxrouter keys
security delete-generic-password -s "com.jxrouter" 2>/dev/null || true
echo "   Removed Keychain entries"

# =============================================================================
# STEP 11: Remove UserDefaults
# =============================================================================
echo ""
echo "11. Removing UserDefaults..."
defaults delete com.marshaljlee.jxproxy 2>/dev/null || true
echo "   Removed UserDefaults"

# =============================================================================
# STEP 12: Clone fresh from GitHub
# =============================================================================
echo ""
echo "12. Cloning fresh from GitHub..."
rm -rf "$BUILD_DIR" 2>/dev/null || true
git clone "$REPO_URL" "$BUILD_DIR" 2>&1 | tail -1
if [ ! -d "$BUILD_DIR/JXRouter.xcodeproj" ]; then
    echo "❌ Clone failed — expected Xcode project not found at $BUILD_DIR"
    exit 1
fi
echo "   Cloned to $BUILD_DIR"

# =============================================================================
# STEP 13: Build
# =============================================================================
echo ""
echo "13. Building JXProxy..."
cd "$BUILD_DIR"
xcodebuild -project JXRouter.xcodeproj -scheme JXRouter -configuration Release SYMROOT="/tmp/JXRouterBuild" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
fi
echo "   Build succeeded"

# =============================================================================
# STEP 14: Deploy
# =============================================================================
echo ""
echo "14. Deploying to /Applications..."
APP_BUNDLE="/tmp/JXRouterBuild/Release/JXRouter.app"
if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ App bundle not found at $APP_BUNDLE"
    exit 1
fi
cp -R "$APP_BUNDLE" /Applications/
codesign --force --deep --sign - /Applications/JXRouter.app 2>/dev/null || true
echo "   Deployed JXProxy to /Applications"

# =============================================================================
# STEP 15: Install CLI launchers
# =============================================================================
echo ""
echo "15. Installing CLI launcher scripts..."

mkdir -p "$LOCAL_BIN"

# jxclaude
cat > "$LOCAL_BIN/jxclaude" << 'LAUNCHER'
#!/bin/bash
JXPROXY_PORT="${JXPROXY_PORT:-5255}"
JXPROXY_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN:-jxproxy}"
export ANTHROPIC_BASE_URL="http://127.0.0.1:${JXPROXY_PORT}"
export ANTHROPIC_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN}"
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=190000
export DISABLE_AUTOUPDATER=1
export DISABLE_FEEDBACK_COMMAND=1
export DISABLE_ERROR_REPORTING=1
echo "🚀 JXProxy: Launching Claude Code on port ${JXPROXY_PORT}..."
REAL_PATH=$(command -v claude 2>/dev/null || true)
if [ -z "$REAL_PATH" ]; then
    for p in /opt/homebrew/bin/claude "$HOME/.npm-global/bin/claude" /usr/local/bin/claude; do
        if [ -x "$p" ]; then REAL_PATH="$p"; break; fi
    done
fi
if [ -z "$REAL_PATH" ]; then
    echo "❌ Claude Code not found. Install: npm install -g @anthropic-ai/claude-code"
    exit 1
fi
exec "$REAL_PATH" "$@"
LAUNCHER
chmod +x "$LOCAL_BIN/jxclaude"

# jxcodex
cat > "$LOCAL_BIN/jxcodex" << 'LAUNCHER'
#!/bin/bash
JXPROXY_PORT="${JXPROXY_PORT:-5255}"
JXPROXY_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN:-jxproxy}"
export OPENAI_BASE_URL="http://127.0.0.1:${JXPROXY_PORT}/v1"
export OPENAI_API_KEY="${JXPROXY_AUTH_TOKEN}"
export CODEX_BASE_URL="http://127.0.0.1:${JXPROXY_PORT}/v1"
export CODEX_API_KEY="${JXPROXY_AUTH_TOKEN}"
echo "🚀 JXProxy: Launching Codex CLI on port ${JXPROXY_PORT}..."
REAL_PATH=$(command -v codex 2>/dev/null || true)
if [ -z "$REAL_PATH" ]; then
    echo "❌ Codex CLI not found. Install from: https://chatgpt.com/codex"
    exit 1
fi
exec "$REAL_PATH" "$@"
LAUNCHER
chmod +x "$LOCAL_BIN/jxcodex"

# jxpi
cat > "$LOCAL_BIN/jxpi" << 'LAUNCHER'
#!/bin/bash
JXPROXY_PORT="${JXPROXY_PORT:-5255}"
JXPROXY_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN:-jxproxy}"
export OPENAI_BASE_URL="http://127.0.0.1:${JXPROXY_PORT}/v1"
export OPENAI_API_KEY="${JXPROXY_AUTH_TOKEN}"
echo "🚀 JXProxy: Launching Pi on port ${JXPROXY_PORT}..."
REAL_PATH=$(command -v pi 2>/dev/null || true)
if [ -z "$REAL_PATH" ]; then
    echo "❌ Pi not found. Install: curl -fsSL https://pi.dev/install.sh | sh"
    exit 1
fi
exec "$REAL_PATH" "$@"
LAUNCHER
chmod +x "$LOCAL_BIN/jxpi"

# jxserver
cat > "$LOCAL_BIN/jxserver" << 'LAUNCHER'
#!/bin/bash
if [ "$1" = "--headless" ]; then
    echo "🚀 JXProxy: Starting proxy server in background (headless)..."
    nohup open "/Applications/JXRouter.app" > /dev/null 2>&1 &
else
    echo "🚀 JXProxy: Starting proxy server..."
    open "/Applications/JXRouter.app"
fi
echo "   Default port: ${JXPROXY_PORT:-5255}"
echo "   Default auth token: ${JXPROXY_AUTH_TOKEN:-jxproxy}"
LAUNCHER
chmod +x "$LOCAL_BIN/jxserver"

echo "   Installed: jxclaude jxcodex jxpi jxserver"

# =============================================================================
# STEP 16: Update PATH
# =============================================================================
echo ""
echo "16. Updating shell PATH..."

add_to_path() {
    local config="$1"
    if [ -f "$config" ]; then
        if ! grep -q "JXPROXY" "$config" 2>/dev/null; then
            {
                echo ""
                echo "# JXProxy Configuration"
                echo "export JXPROXY_PORT=\"5255\""
                echo "export JXPROXY_AUTH_TOKEN=\"jxproxy\""
                echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
            } >> "$config"
            echo "   Added JXProxy config to $config"
        fi
    fi
}

add_to_path "$HOME/.zshrc"
add_to_path "$HOME/.bashrc"
export PATH="$LOCAL_BIN:$PATH"

# =============================================================================
# STEP 17: Desktop shortcut
# =============================================================================
echo ""
echo "17. Creating desktop shortcut..."
ln -sf "/Applications/JXRouter.app" "$HOME/Desktop/JXProxy.app" 2>/dev/null || true
echo "   Created desktop shortcut"

# =============================================================================
# DONE
# =============================================================================
echo ""
echo "==========================================="
echo " ✅ JXProxy Reinstall Complete!"
echo "==========================================="
echo ""
echo "   Launch:      jxserver"
echo "   Claude Code: jxclaude"
echo "   Codex:       jxcodex"
echo "   Pi:          jxpi"
echo ""
echo "   Port:        5255"
echo "   Auth token:  jxproxy"
echo ""
echo "   Or open from: /Applications/JXRouter.app"
echo "==========================================="
