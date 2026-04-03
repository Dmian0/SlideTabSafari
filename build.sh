#!/bin/bash
echo "Building SlideTabSafari..."
APP_NAME="SlideTabSafari"
APP_BUNDLE="${APP_NAME}.app"

# Remove old build
rm -rf "$APP_BUNDLE"

# Create directories
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Compile Swift code
swiftc main.swift -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
if [ $? -ne 0 ]; then
    echo "Compilation failed."
    exit 1
fi

# Copy Info.plist and Icon
cp Info.plist "$APP_BUNDLE/Contents/"
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
fi

echo "Build complete. Signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Done. App is at: $PWD/$APP_BUNDLE"
