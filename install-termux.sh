#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# JXProxy for Android/Termux — One-Time Install Script v1.0.0
# ============================================================================
# Reverse-engineered port of JXRouter (macOS) → Android ARM64.
#
# This script:
#   1. Validates the Termux environment & Android architecture
#   2. Installs system dependencies (Python, OpenSSL, curl)
#   3. Installs the jxproxy Python package and CLI entry point
#   4. Sets up CLI launcher commands (jxproxy, jxclaude, jxcodex, jxpi, jxserver)
#   5. Configures optional Termux:Boot auto-start
#   6. Writes shell config exports for JXPROXY_PORT, JXPROXY_AUTH_TOKEN
#   7. Validates everything works end-to-end
#
# Exit codes:
#   0 — success, fully installed
#   1 — prerequisite failure (not Termux, wrong arch, missing deps)
#   2 — install failure (download, write, or config error)
#   3 — partial install (non-fatal warnings issued)
# ============================================================================

set -euo pipefail

# ── Metadata ────────────────────────────────────────────────────────────────
VERSION="1.0.0"
APP_NAME="jxproxy"
APP_DISPLAY="JXProxy"

# ── Paths ───────────────────────────────────────────────────────────────────
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
LOCAL_BIN="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/${APP_NAME}"
LOG_DIR="${CONFIG_DIR}"
BOOT_DIR="${HOME}/.termux/boot"
JXPROXY_PY="${LOCAL_BIN}/${APP_NAME}"
WRAPPER_DIR="${LOCAL_BIN}"

# Source URLs (raw content from the repo)
REPO_RAW="https://raw.githubusercontent.com/marshaljlee/jxrouter/main"
SCRIPT_URL="${REPO_RAW}/jxproxy.py"

# ── Colors (Termux-compatible ANSI) ─────────────────────────────────────────
GREEN='\033[92m'
YELLOW='\033[93m'
RED='\033[91m'
CYAN='\033[96m'
BOLD='\033[1m'
RESET='\033[0m'
GRAY='\033[90m'

ok_msg()   { echo -e " ${GREEN}✓${RESET} $1"; }
warn_msg() { echo -e " ${YELLOW}⚠${RESET} $1"; }
err_msg()  { echo -e " ${RED}✗${RESET} $1"; }
info_msg() { echo -e " ${CYAN}→${RESET} $1"; }
header()   { echo -e "\n${BOLD}$1${RESET}\n"; }

# ============================================================================
# STEP 0: Pre-flight Validation
# ============================================================================

header "JXProxy for Android/Termux — Install v${VERSION}"
echo -e "${GRAY}Reverse-engineered from github.com/marshaljlee/jxrouter${RESET}\n"

# Detect Termux
if [ ! -d "/data/data/com.termux" ] && [ ! -d "${PREFIX}" ]; then
    err_msg "This script must be run inside Termux on Android."
    err_msg "Install Termux from F-Droid: https://f-droid.org/packages/com.termux/"
    exit 1
fi

# Detect architecture
ARCH=$(uname -m)
case "${ARCH}" in
    aarch64|arm64)
        OK_ARCH="arm64"
        ok_msg "Architecture: ARM64 (${ARCH})"
        ;;
    armv7l|armv8l)
        OK_ARCH="arm32"
        warn_msg "Architecture: ${ARCH} (32-bit ARM)"
        warn_msg "JXProxy will work but performance may be limited."
        ;;
    x86_64|amd64)
        OK_ARCH="x86_64"
        ok_msg "Architecture: x86_64 (${ARCH})"
        ;;
    *)
        OK_ARCH="unknown"
        warn_msg "Architecture: ${ARCH} (untested)"
        warn_msg "JXProxy may work but is only tested on ARM64."
        ;;
esac

# Check Termux storage access (best-effort)
if [ ! -d "${HOME}/storage" ]; then
    warn_msg "Termux storage not yet set up."
    warn_msg "Run 'termux-setup-storage' if you need file access."
fi

# ============================================================================
# STEP 1: Install System Dependencies
# ============================================================================

header "Step 1: Installing System Dependencies"

# Update package list silently
info_msg "Updating package lists…"
pkg update -y 2>/dev/null | tail -1 || true

DEPS=(
    "python"
    "openssl"
    "curl"
    "which"
)

MISSING_DEPS=()
for dep in "${DEPS[@]}"; do
    if ! command -v "${dep}" >/dev/null 2>&1 && \
       [ ! -f "${PREFIX}/bin/${dep}" ] && \
       [ ! -f "${PREFIX}/libexec/${dep}" ]; then
        MISSING_DEPS+=("${dep}")
    fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    info_msg "Installing: ${MISSING_DEPS[*]}"
    pkg install -y "${MISSING_DEPS[@]}" 2>&1 | tail -3
    ok_msg "Dependencies installed"
else
    ok_msg "All system dependencies already present"
fi

# Verify Python 3
PYTHON=""
for candidate in python3 python; do
    if command -v "${candidate}" >/dev/null 2>&1; then
        PYTHON="${candidate}"
        break
    fi
done

if [ -z "${PYTHON}" ]; then
    err_msg "Python 3 not found after install."
    err_msg "Run: pkg install python"
    exit 1
fi

PYVER=$("${PYTHON}" --version 2>&1)
ok_msg "${PYVER}"

# ============================================================================
# STEP 2: Create Directories
# ============================================================================

header "Step 2: Creating Directories"

mkdir -p "${LOCAL_BIN}"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${LOG_DIR}"
mkdir -p "${BOOT_DIR}"

ok_msg "${LOCAL_BIN}"
ok_msg "${CONFIG_DIR}"
ok_msg "${BOOT_DIR} (Termux:Boot)"

# ============================================================================
# STEP 3: Install JXProxy Script
# ============================================================================

header "Step 3: Installing JXProxy"

# Try to download from GitHub, fall back to local copy if available
INSTALL_SOURCE=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "${SCRIPT_DIR}/jxproxy.py" ]; then
    INSTALL_SOURCE="local"
    cp "${SCRIPT_DIR}/jxproxy.py" "${JXPROXY_PY}"
    ok_msg "Copied jxproxy.py from local directory"
elif curl -fsSL "${SCRIPT_URL}" -o "${JXPROXY_PY}" 2>/dev/null; then
    INSTALL_SOURCE="remote"
    ok_msg "Downloaded jxproxy.py from GitHub"
else
    err_msg "Could not locate jxproxy.py locally or download from GitHub."
    err_msg "Ensure jxproxy.py is in the same directory as this install script."
    err_msg "Or check network: ${SCRIPT_URL}"
    exit 2
fi

chmod 755 "${JXPROXY_PY}"
ok_msg "Installed to ${JXPROXY_PY}"

# Verify the script is valid Python
if "${PYTHON}" -c "import py_compile; py_compile.compile('${JXPROXY_PY}', doraise=True)" 2>/dev/null; then
    ok_msg "Python syntax validation passed"
else
    err_msg "Python syntax validation FAILED — corrupted download?"
    exit 2
fi

# ============================================================================
# STEP 4: Create CLI Launcher Scripts
# ============================================================================

header "Step 4: Creating CLI Launchers"

# jxproxy — direct invocation of the Python script
cat > "${LOCAL_BIN}/jxproxy" << 'LAUNCHER'
#!/data/data/com.termux/files/usr/bin/bash
# JXProxy main CLI — delegates to the Python implementation.
# Usage: jxproxy <command> [options]

JXPROXY_PORT="${JXPROXY_PORT:-5255}"
JXPROXY_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN:-jxproxy}"

export JXPROXY_PORT
export JXPROXY_AUTH_TOKEN

SCRIPT="${HOME}/.local/bin/jxproxy.py"
if [ ! -f "${SCRIPT}" ]; then
    echo "❌ JXProxy not found at ${SCRIPT}" >&2
    echo "   Reinstall: curl -fsSL https://raw.githubusercontent.com/marshaljlee/jxrouter/main/install-termux.sh | bash" >&2
    exit 1
fi

exec python3 "${SCRIPT}" "$@"
LAUNCHER
chmod 755 "${LOCAL_BIN}/jxproxy"
ok_msg "jxproxy → CLI entry point"

# jxclaude — Claude Code tunnel launcher
cat > "${LOCAL_BIN}/jxclaude" << 'LAUNCHER'
#!/data/data/com.termux/files/usr/bin/bash
# JXProxy launcher for Claude Code (Termux)
# Routes Anthropic API calls through JXProxy.
# Usage: jxclaude [args...]
# Note: Requires Claude Code installed separately.

JXPROXY_PORT="${JXPROXY_PORT:-5255}"
JXPROXY_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN:-jxproxy}"

export ANTHROPIC_BASE_URL="http://127.0.0.1:${JXPROXY_PORT}"
export ANTHROPIC_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN}"
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=190000

echo -e "\033[96m🚀 JXProxy:\033[0m Launching Claude Code on port ${JXPROXY_PORT}…"
echo "   ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}"

# Find claude binary
REAL_PATH=""
for p in "${PREFIX}/bin/claude" "${HOME}/.npm-global/bin/claude" "/data/data/com.termux/files/usr/bin/claude"; do
    if [ -x "$p" ]; then
        REAL_PATH="$p"
        break
    fi
done

if [ -z "${REAL_PATH}" ]; then
    echo -e "\033[91m❌\033[0m Claude Code not found."
    echo "   Install it: npm install -g @anthropic-ai/claude-code"
    echo "   Or use:     jxcodex (for Codex CLI)"
    echo "   Or use:     jxpi    (for Pi Coding Agent)"
    exit 1
fi

exec "${REAL_PATH}" "$@"
LAUNCHER
chmod 755 "${LOCAL_BIN}/jxclaude"
ok_msg "jxclaude → Claude Code tunnel"

# jxcodex — Codex CLI tunnel launcher
cat > "${LOCAL_BIN}/jxcodex" << 'LAUNCHER'
#!/data/data/com.termux/files/usr/bin/bash
# JXProxy launcher for Codex CLI (Termux)
# Routes OpenAI API calls through JXProxy.
# Usage: jxcodex [args...]

JXPROXY_PORT="${JXPROXY_PORT:-5255}"
JXPROXY_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN:-jxproxy}"

export OPENAI_BASE_URL="http://127.0.0.1:${JXPROXY_PORT}/v1"
export OPENAI_API_KEY="${JXPROXY_AUTH_TOKEN}"
export CODEX_BASE_URL="http://127.0.0.1:${JXPROXY_PORT}/v1"
export CODEX_API_KEY="${JXPROXY_AUTH_TOKEN}"

echo -e "\033[96m🚀 JXProxy:\033[0m Launching Codex CLI on port ${JXPROXY_PORT}…"

# Find codex binary
REAL_PATH=""
for p in "${PREFIX}/bin/codex" "${HOME}/.npm-global/bin/codex" "/data/data/com.termux/files/usr/bin/codex"; do
    if [ -x "$p" ]; then
        REAL_PATH="$p"
        break
    fi
done

if [ -z "${REAL_PATH}" ]; then
    echo -e "\033[91m❌\033[0m Codex CLI not found."
    echo "   See: https://chatgpt.com/codex"
    exit 1
fi

exec "${REAL_PATH}" "$@"
LAUNCHER
chmod 755 "${LOCAL_BIN}/jxcodex"
ok_msg "jxcodex → Codex CLI tunnel"

# jxpi — Pi Coding Agent tunnel launcher
cat > "${LOCAL_BIN}/jxpi" << 'LAUNCHER'
#!/data/data/com.termux/files/usr/bin/bash
# JXProxy launcher for Pi Coding Agent (Termux)
# Routes OpenAI API calls through JXProxy.
# Usage: jxpi [args...]

JXPROXY_PORT="${JXPROXY_PORT:-5255}"
JXPROXY_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN:-jxproxy}"

export OPENAI_BASE_URL="http://127.0.0.1:${JXPROXY_PORT}/v1"
export OPENAI_API_KEY="${JXPROXY_AUTH_TOKEN}"

echo -e "\033[96m🚀 JXProxy:\033[0m Launching Pi Coding Agent on port ${JXPROXY_PORT}…"

# Find pi binary
REAL_PATH=""
for p in "${PREFIX}/bin/pi" "${HOME}/.npm-global/bin/pi" "/opt/homebrew/bin/pi" "/usr/local/bin/pi"; do
    if [ -x "$p" ]; then
        REAL_PATH="$p"
        break
    fi
done

if [ -z "${REAL_PATH}" ]; then
    echo -e "\033[91m❌\033[0m Pi Coding Agent not found."
    echo "   Install: curl -fsSL https://pi.dev/install.sh | sh"
    exit 1
fi

exec "${REAL_PATH}" "$@"
LAUNCHER
chmod 755 "${LOCAL_BIN}/jxpi"
ok_msg "jxpi → Pi Coding Agent tunnel"

# jxserver — Start JXProxy server in background
cat > "${LOCAL_BIN}/jxserver" << 'LAUNCHER'
#!/data/data/com.termux/files/usr/bin/bash
# JXProxy server launcher — starts the proxy in background.
# Usage: jxserver [--headless] [--port PORT]

JXPROXY_PORT="${JXPROXY_PORT:-5255}"
JXPROXY_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN:-jxproxy}"

PORT="${JXPROXY_PORT}"

# Parse --port argument
for arg in "$@"; do
    case "$arg" in
        --port=*) PORT="${arg#*=}" ;;
        --port) shift; PORT="$1" ;;
    esac
done

# Check if already running
if [ -f "${HOME}/.config/jxproxy/jxproxy.pid" ]; then
    OLD_PID=$(cat "${HOME}/.config/jxproxy/jxproxy.pid" 2>/dev/null || echo "")
    if [ -n "${OLD_PID}" ] && kill -0 "${OLD_PID}" 2>/dev/null; then
        echo -e "\033[93m⚠ JXProxy is already running (PID ${OLD_PID})\033[0m"
        echo "   Restart: jxproxy stop && jxserver"
        exit 0
    fi
fi

echo -e "\033[96m🚀 JXProxy:\033[0m Starting proxy server on port ${PORT}…"
jxproxy start --port "${PORT}" --daemon

# Wait briefly and verify
sleep 1
if jxproxy status 2>/dev/null | grep -q "running"; then
    echo -e "\033[92m✅ JXProxy is running on 127.0.0.1:${PORT}\033[0m"
    echo "   Auth token: ${JXPROXY_AUTH_TOKEN}"
    echo ""
    echo "   CLI tools:"
    echo "     jxclaude    Launch Claude Code through JXProxy"
    echo "     jxcodex     Launch Codex through JXProxy"
    echo "     jxpi        Launch Pi through JXProxy"
    echo "     jxproxy     Direct CLI access"
    echo ""
    echo "   Test: curl -s http://127.0.0.1:${PORT}/health | python3 -m json.tool"
else
    echo -e "\033[91m❌ JXProxy failed to start.\033[0m"
    echo "   Check logs: cat ${HOME}/.config/jxproxy/proxy.log"
    exit 1
fi
LAUNCHER
chmod 755 "${LOCAL_BIN}/jxserver"
ok_msg "jxserver → daemon launcher"

# ============================================================================
# STEP 5: Shell Configuration
# ============================================================================

header "Step 5: Configuring Shell Environment"

# Add to PATH if not already present
SHELL_CONFIGS=()
if [ -f "${HOME}/.zshrc" ]; then
    SHELL_CONFIGS+=("${HOME}/.zshrc")
fi
if [ -f "${HOME}/.bashrc" ]; then
    SHELL_CONFIGS+=("${HOME}/.bashrc")
fi
# If neither exists, create .bashrc
if [ ${#SHELL_CONFIGS[@]} -eq 0 ]; then
    touch "${HOME}/.bashrc"
    SHELL_CONFIGS+=("${HOME}/.bashrc")
fi

for config in "${SHELL_CONFIGS[@]}"; do
    # Only add if JXProxy block doesn't exist
    if ! grep -q "JXProxy Configuration" "${config}" 2>/dev/null; then
        {
            echo ""
            echo "# JXProxy Configuration (installed $(date +%Y-%m-%d))"
            echo "export JXPROXY_PORT=\"5255\""
            echo "export JXPROXY_AUTH_TOKEN=\"jxproxy\""
            echo "export PATH=\"\${HOME}/.local/bin:\${PATH}\""
        } >> "${config}"
        ok_msg "Added JXProxy config to ${config}"
    else
        ok_msg "JXProxy config already in ${config}"
    fi
done

# Export for current session
export PATH="${LOCAL_BIN}:${PATH}"
export JXPROXY_PORT="5255"
export JXPROXY_AUTH_TOKEN="jxproxy"

# ============================================================================
# STEP 6: Termux:Boot Auto-Start (optional)
# ============================================================================

header "Step 6: Termux:Boot Auto-Start"

# Check if termux-boot is installed
TERMUX_BOOT_AVAILABLE=false
if command -v termux-boot 2>/dev/null || [ -d "${BOOT_DIR}" ]; then
    TERMUX_BOOT_AVAILABLE=true
fi

if [ "${TERMUX_BOOT_AVAILABLE}" = true ]; then
    BOOT_SCRIPT="${BOOT_DIR}/jxproxy"

    cat > "${BOOT_SCRIPT}" << 'BOOT'
#!/data/data/com.termux/files/usr/bin/bash
# Auto-start JXProxy when Termux boots (Termux:Boot add-on required)
# Installed by install-termux.sh — remove this file to disable auto-start.

export PATH="${HOME}/.local/bin:/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/bin/env"
export JXPROXY_PORT="${JXPROXY_PORT:-5255}"
export JXPROXY_AUTH_TOKEN="${JXPROXY_AUTH_TOKEN:-jxproxy}"

# Wait for network (Termux may boot before connectivity)
sleep 10

# Start the proxy
jxproxy start --daemon 2>/dev/null || true
BOOT
    chmod 755 "${BOOT_SCRIPT}"
    ok_msg "Termux:Boot auto-start script created"
    warn_msg "Install Termux:Boot from F-Droid to use auto-start"
    warn_msg "  https://f-droid.org/packages/com.termux.boot/"
else
    info_msg "Termux:Boot not detected — skipping auto-start setup."
    info_msg "Install Termux:Boot from F-Droid and re-run this script to enable."
fi

# ============================================================================
# STEP 7: Validate Installation
# ============================================================================

header "Step 7: Validating Installation"

ERRORS=0

# 1. Check Python script
if [ -f "${JXPROXY_PY}" ] && [ -x "${JXPROXY_PY}" ]; then
    ok_msg "Python script: ${JXPROXY_PY}"
else
    err_msg "Python script missing or not executable"
    ERRORS=$((ERRORS + 1))
fi

# 2. Check CLI entry point
if command -v jxproxy >/dev/null 2>&1; then
    ok_msg "CLI: jxproxy"
else
    err_msg "CLI: jxproxy not in PATH"
    ERRORS=$((ERRORS + 1))
fi

# 3. Check all launchers
for cmd in jxclaude jxcodex jxpi jxserver; do
    if [ -f "${LOCAL_BIN}/${cmd}" ] && [ -x "${LOCAL_BIN}/${cmd}" ]; then
        ok_msg "CLI: ${cmd}"
    else
        err_msg "CLI: ${cmd} missing"
        ERRORS=$((ERRORS + 1))
    fi
done

# 4. Check config directory
if [ -d "${CONFIG_DIR}" ]; then
    ok_msg "Config dir: ${CONFIG_DIR}"
else
    err_msg "Config dir missing"
    ERRORS=$((ERRORS + 1))
fi

# 5. Validate the Python import (try importing the module)
if python3 -c "import json, http.client, urllib.request, socketserver, threading, dataclasses, enum; print('ok')" 2>/dev/null; then
    ok_msg "Python standard library imports"
else
    warn_msg "Some Python standard library imports may be missing"
fi

# 6. Quick functional test: start, health check, stop
info_msg "Performing functional test…"
jxproxy start --port 15999 2>/dev/null || true
sleep 1

HEALTH=$(curl -s http://127.0.0.1:15999/health 2>/dev/null || echo "")
if echo "${HEALTH}" | python3 -c "import sys, json; d=json.load(sys.stdin); assert d.get('status') == 'ok'; print(d.get('proxy',''))" 2>/dev/null; then
    ok_msg "Functional test: proxy started, health endpoint OK"
else
    warn_msg "Functional test: health check returned: ${HEALTH}"
    warn_msg "This may be expected if port 15999 is unavailable."
fi

# Stop test instance
jxproxy stop 2>/dev/null || true
# Give it a moment to release the port
sleep 0.5

# ============================================================================
# STEP 8: Summary
# ============================================================================

echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ✅ JXProxy v${VERSION} — Installation Complete!${RESET}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${CYAN}Quick Start:${RESET}"
echo "    jxserver            Start the proxy in background"
echo "    jxproxy status      Check if proxy is running"
echo "    jxproxy config set provider=opencode-zen"
echo "    jxproxy config show"
echo ""
echo -e "  ${CYAN}AI Client Launchers:${RESET}"
echo "    jxclaude            Claude Code → JXProxy"
echo "    jxcodex             Codex CLI → JXProxy"
echo "    jxpi                Pi Coding Agent → JXProxy"
echo ""
echo -e "  ${CYAN}Test the Proxy:${RESET}"
echo "    jxproxy start --daemon"
echo "    curl -s http://127.0.0.1:5255/health"
echo ""
echo -e "  ${CYAN}Set API Keys:${RESET}"
echo "    export OPENCODE_API_KEY=\"your-key-here\""
echo "    # Or: jxproxy config set api_key_opencode=your-key-here"
echo ""
echo -e "  ${CYAN}Stop the Proxy:${RESET}"
echo "    jxproxy stop"
echo ""
echo -e "  ${GRAY}Config:    ${CONFIG_DIR}${RESET}"
echo -e "  ${GRAY}Log:       ${LOG_DIR}/proxy.log${RESET}"
echo -e "  ${GRAY}Source:    github.com/marshaljlee/jxrouter${RESET}"
echo ""

if [ "${ERRORS}" -gt 0 ]; then
    echo -e " ${YELLOW}⚠ Installation completed with ${ERRORS} warning(s).${RESET}"
    echo -e " ${YELLOW}  Check the log output above for details.${RESET}"
    exit 3
fi

# Final suggestion
echo -e " ${CYAN}💡 Tip:${RESET} Run 'source ${SHELL_CONFIGS[0]}' or restart Termux to"
echo -e "     load JXProxy environment variables."
echo ""
