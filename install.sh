#!/bin/zsh

echo "==========================================="
echo " Installing JXRouter"
echo "==========================================="

# Check for Xcode CLI tools
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "Error: xcodebuild not found. Please run 'xcode-select --install'"
    exit 1
fi

echo "1. Cleaning previous builds..."
rm -rf /tmp/JXRouterBuild 2>/dev/null
rm -rf Build/ 2>/dev/null

echo "2. Stripping extended attributes..."
# Strip iCloud and quarantine attributes to prevent codesign issues
xattr -cr . 2>/dev/null

echo "3. Building JXRouter..."
xcodebuild -project JXRouter.xcodeproj -scheme JXRouter -configuration Release SYMROOT="/tmp/JXRouterBuild" > /dev/null

if [ $? -ne 0 ]; then
    echo "Build failed! Check xcodebuild output."
    exit 1
fi

echo "4. Deploying to /Applications..."
APP_BUNDLE="/tmp/JXRouterBuild/Release/JXRouter.app"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: App bundle not found at $APP_BUNDLE"
    exit 1
fi

# Remove existing app if present
rm -rf /Applications/JXRouter.app

# Copy new build
cp -R "$APP_BUNDLE" /Applications/

# Sign the app in /Applications
codesign --force --deep --sign - /Applications/JXRouter.app 2>/dev/null

echo "5. Updating environment paths..."
ZSHRC="$HOME/.zshrc"
if ! grep -q "JX_PROXY_URL" "$ZSHRC" 2>/dev/null; then
    echo "" >> "$ZSHRC"
    echo "# JXRouter Env Variables" >> "$ZSHRC"
    echo "export JX_PROXY_URL=\"http://127.0.0.1:5255\"" >> "$ZSHRC"
    echo "export HTTP_PROXY=\"\$JX_PROXY_URL\"" >> "$ZSHRC"
    echo "export HTTPS_PROXY=\"\$JX_PROXY_URL\"" >> "$ZSHRC"
    echo "export ALL_PROXY=\"\$JX_PROXY_URL\"" >> "$ZSHRC"
fi

echo "==========================================="
echo " ✅ Installation Complete!"
echo " JXRouter is now in your Applications folder."
echo " You can launch it by running: open /Applications/JXRouter.app"
echo "==========================================="
