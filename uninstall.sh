#!/bin/zsh
set -eu

echo "==========================================="
echo " Uninstalling JXProxy"
echo "==========================================="
echo ""

# Check for running processes
RUNNING=false
if pgrep -x JXRouter >/dev/null 2>&1; then
    RUNNING=true
    echo "⚠️  JXProxy is currently running."
    echo "   Stopping JXProxy..."
    killall JXRouter 2>/dev/null || true
    sleep 1
fi

echo ""
echo "1. Removing JXProxy app..."
if [ -d "/Applications/JXRouter.app" ]; then
    rm -rf "/Applications/JXRouter.app"
    echo "   Removed /Applications/JXRouter.app"
fi

echo ""
echo "2. Removing desktop shortcuts..."
rm -f "$HOME/Desktop/JXProxy.app" 2>/dev/null || true

echo ""
echo "3. Removing CLI launcher scripts..."
LOCAL_BIN="${HOME}/.local/bin"
rm -f "$LOCAL_BIN/jxclaude" 2>/dev/null || true
rm -f "$LOCAL_BIN/jxcodex" 2>/dev/null || true
rm -f "$LOCAL_BIN/jxpi" 2>/dev/null || true
rm -f "$LOCAL_BIN/jxserver" 2>/dev/null || true

echo ""
echo "4. Cleaning up shell config..."

clean_shell_config() {
    local config="$1"
    if [ -f "$config" ]; then
        # Remove JXProxy block
        if grep -q "JXPROXY" "$config" 2>/dev/null; then
            # Remove comment lines and export lines
            sed -i '' '/^# JXProxy Configuration/d' "$config" 2>/dev/null || true
            sed -i '' '/^export JXPROXY_PORT/d' "$config" 2>/dev/null || true
            sed -i '' '/^export JXPROXY_AUTH_TOKEN/d' "$config" 2>/dev/null || true
            sed -i '' '/^export PATH.*local\/bin/d' "$config" 2>/dev/null || true
            echo "   Cleaned $config"
        fi
    fi
}

clean_shell_config "$HOME/.zshrc"
clean_shell_config "$HOME/.bashrc"

echo ""
echo "5. Cleaning up build artifacts..."
rm -rf /tmp/JXRouterBuild 2>/dev/null || true
rm -rf Build/ 2>/dev/null || true

echo ""
echo "6. DNS redirection cleanup (requires admin)..."
echo "   Attempting to remove DNS hijack entries..."
sudo sed -i '' '/# JXProxy DNS Hijack/,/# End JXProxy DNS Hijack/d' /etc/hosts 2>/dev/null || true
sudo dscacheutil -flushcache 2>/dev/null || true
sudo killall -HUP mDNSResponder 2>/dev/null || true

echo ""
echo "==========================================="
echo " ✅ JXProxy Uninstalled!"
echo "==========================================="
echo ""
echo " The following were kept:"
echo "   - Claude Code (npm package)"
echo "   - Codex CLI"
echo "   - uv and Python packages"
echo "   - Shared PATH entries"
echo ""
echo " To reinstall, run: ./install.sh"
echo ""
