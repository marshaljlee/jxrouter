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
        # Remove JXProxy block (config + protective alias + End marker)
        if grep -q "JXPROXY" "$config" 2>/dev/null; then
            # Remove the whole block between the markers (inclusive)
            sed -i '' '/^# JXProxy Configuration/,/^# End JXProxy$/d' "$config" 2>/dev/null || true
            # Remove comment lines and export lines left behind
            sed -i '' '/^# JXProxy Configuration/d' "$config" 2>/dev/null || true
            sed -i '' '/^# JXProxy protective alias/d' "$config" 2>/dev/null || true
            sed -i '' '/^# jxproxy protective alias/d' "$config" 2>/dev/null || true
            sed -i '' '/^# End JXProxy/d' "$config" 2>/dev/null || true
            sed -i '' '/^export JXPROXY_PORT/d' "$config" 2>/dev/null || true
            sed -i '' '/^export JXPROXY_AUTH_TOKEN/d' "$config" 2>/dev/null || true
            sed -i '' '/^export PATH.*local\/bin/d' "$config" 2>/dev/null || true
            sed -i '' '/alias claude="unset ANTHROPIC_DEFAULT/d' "$config" 2>/dev/null || true
            echo "   Cleaned $config"
        fi
    fi
}

clean_shell_config "$HOME/.zshrc"
clean_shell_config "$HOME/.bashrc"

echo ""
echo "5. Restoring Claude Code settings (~/.claude/settings.json)..."
# Remove the routing env block JXProxy wrote while running. If the app
# left a backup, restore it; otherwise strip only the managed keys.
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_BACKUP="$HOME/.claude/settings.json.jxproxy-bak"
if [ -f "$CLAUDE_BACKUP" ]; then
    rm -f "$CLAUDE_SETTINGS" 2>/dev/null || true
    mv "$CLAUDE_BACKUP" "$CLAUDE_SETTINGS" 2>/dev/null || true
    echo "   Restored original settings.json from backup"
elif [ -f "$CLAUDE_SETTINGS" ]; then
    python3 - "$CLAUDE_SETTINGS" << 'PY' 2>/dev/null || true
import json, sys
path = sys.argv[1]
keys = ["ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
        "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL"]
try:
    with open(path) as f: data = json.load(f)
    env = data.get("env", {})
    for k in keys: env.pop(k, None)
    if env: data["env"] = env
    else: data.pop("env", None)
    with open(path, "w") as f: json.dump(data, f, indent=2)
    print("   Stripped JXProxy env keys from settings.json")
except Exception:
    pass
PY
fi

rm -f "$CLAUDE_BACKUP" 2>/dev/null || true

echo ""
echo "6. Cleaning up build artifacts..."
rm -rf /tmp/JXRouterBuild 2>/dev/null || true

echo ""
echo "7. DNS hijack cleanup..."
# DNS hijacking is permanently retired. Only escalate when /etc/hosts
# actually contains leftover hijack blocks from old app versions.
# On a modern install this is a complete no-op — zero password prompts.
if grep -qE "DNS Hijack" /etc/hosts 2>/dev/null; then
    echo "   Found leftover DNS hijack entries — cleaning (requires admin)..."
    echo "   You may be prompted for your password..."
    CLEANUP_SCRIPT="cp /etc/hosts /etc/hosts.jxproxy.backup;"
    CLEANUP_SCRIPT="$CLEANUP_SCRIPT sed -i '' '/# JXProxy DNS Hijack/,/# End JXProxy DNS Hijack/d' /etc/hosts;"
    CLEANUP_SCRIPT="$CLEANUP_SCRIPT sed -i '' '/# ProxySwitch DNS Hijack/,/# End ProxySwitch DNS Hijack/d' /etc/hosts;"
    CLEANUP_SCRIPT="$CLEANUP_SCRIPT /sbin/pfctl -a com.apple/250.jxproxy -F all 2>/dev/null || true;"
    CLEANUP_SCRIPT="$CLEANUP_SCRIPT /usr/bin/dscacheutil -flushcache 2>/dev/null || true;"
    CLEANUP_SCRIPT="$CLEANUP_SCRIPT /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true;"
    osascript -e "do shell script \"$CLEANUP_SCRIPT\" with administrator privileges" 2>/dev/null && \
        echo "   Removed DNS hijack and pf anchor" || \
        echo "   ⚠️  DNS cleanup skipped (admin not granted)"
else
    echo "   No DNS hijack entries found — no admin needed"
    /sbin/pfctl -a com.apple/250.jxproxy -F all 2>/dev/null || true
fi

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
