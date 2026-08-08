#!/bin/zsh
set -eu

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

echo ""
echo "1. Cleaning previous builds..."
rm -rf /tmp/JXRouterBuild 2>/dev/null

echo ""
echo "3. Building JXProxy..."
xcodebuild -project JXRouter.xcodeproj -scheme JXRouter -configuration Release SYMROOT="/tmp/JXRouterBuild" > /dev/null

if [ $? -ne 0 ]; then
    echo "Build failed! Check xcodebuild output."
    exit 1
fi

echo ""
echo "3b. Bundling agent resources..."
APP_BUNDLE="/tmp/JXRouterBuild/Release/JXRouter.app"
RESOURCES_SRC="$(dirname "$0")/JXRouter/Resources"
RESOURCES_DST="$APP_BUNDLE/Contents/Resources"

if [ -d "$RESOURCES_SRC" ]; then
    cp "$RESOURCES_SRC/AGENTS.md" "$RESOURCES_DST/AGENTS.md"
    mkdir -p "$RESOURCES_DST/skills"
    cp -R "$RESOURCES_SRC/skills/"* "$RESOURCES_DST/skills/"
    echo "   Bundled AGENTS.md + 5 skill SKILL.md files"
else
    echo "   WARNING: Resources/ directory not found at $RESOURCES_SRC"
fi

echo ""
echo "4. Deploying to /Applications..."
APP_BUNDLE="/tmp/JXRouterBuild/Release/JXRouter.app"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: App bundle not found at $APP_BUNDLE"
    exit 1
fi

# Remove existing app if present
killall JXRouter 2>/dev/null || true
rm -rf "/Applications/JXRouter.app" 2>/dev/null || true
rm -rf "/Applications/JXProxy.app" 2>/dev/null || true

# Copy new build
cp -R "$APP_BUNDLE" /Applications/

# Strip stray extended attributes on the deployed bundle only (never the repo)
xattr -cr "/Applications/JXRouter.app" 2>/dev/null || true

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
export ANTHROPIC_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN}"
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
    nohup open "/Applications/JXRouter.app" > /dev/null 2>&1 &
    echo "   PID: $!"
else
    echo "🚀 JXProxy: Starting proxy server..."
    open "/Applications/JXRouter.app"
fi
echo "   Use the menu bar icon to control JXProxy."
echo "   Default proxy port: ${JXPROXY_PORT:-5255}"
echo "   Auth token: ${JXPROXY_AUTH_TOKEN:-jxproxy}"
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

ln -sf "/Applications/JXRouter.app" "$HOME/Desktop/JXProxy.app" 2>/dev/null || true

echo ""
echo "==========================================="
echo " ✅ JXProxy Installation Complete!"
echo "==========================================="
echo ""
echo " JXProxy is now installed in /Applications/JXRouter.app"
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
echo " You can launch it by running: open /Applications/JXRouter.app"
echo " Or click the desktop shortcut: JXProxy"
echo ""
echo " For VS Code Claude Code extension, add to settings.json:"
echo '   "claudeCode.environmentVariables": ['
echo '     { "name": "ANTHROPIC_BASE_URL", "value": "http://127.0.0.1:'${JXPROXY_PORT}'" },'
echo '     { "name": "ANTHROPIC_AUTH_TOKEN", "value": "'${JXPROXY_AUTH_TOKEN}'" },'
echo '     { "name": "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY", "value": "1" }'
echo '   ]'
echo ""
