#!/bin/sh
set -eu

TASK_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$TASK_ROOT"

export SWIFT_MODULECACHE_PATH="$TASK_ROOT/.swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.swift-module-cache"
mkdir -p "$TASK_ROOT/.tmp" "$TASK_ROOT/.cache/swift"
export TMPDIR="$TASK_ROOT/.tmp"
swift run --disable-sandbox --cache-path "$TASK_ROOT/.cache/swift" --config-path "$TASK_ROOT/.cache/config" --security-path "$TASK_ROOT/.cache/security" -c debug XContentAssistantCoreTestRunner
swift build --disable-sandbox --cache-path "$TASK_ROOT/.cache/swift" --config-path "$TASK_ROOT/.cache/config" --security-path "$TASK_ROOT/.cache/security" -c release --arch arm64
# Reuse the already validated icon; this release changes the reply flow, not its artwork.
if [ ! -s "$TASK_ROOT/Resources/AppIcon.icns" ]; then
    swift -module-cache-path "$TASK_ROOT/.swift-module-cache" "$TASK_ROOT/Scripts/make-icon.swift" "$TASK_ROOT/Resources/AppIcon.iconset"
    iconutil -c icns "$TASK_ROOT/Resources/AppIcon.iconset" -o "$TASK_ROOT/Resources/AppIcon.icns"
fi

APP_ROOT="$TASK_ROOT/dist/X 素材助手.app"
if [ -e "$APP_ROOT" ]; then mv "$APP_ROOT" "$TASK_ROOT/dist/X 素材助手-$(date +%Y%m%d-%H%M%S).app"; fi
mkdir -p "$APP_ROOT/Contents/MacOS" "$APP_ROOT/Contents/Resources"
cp "$TASK_ROOT/.build/arm64-apple-macosx/release/XContentAssistant" "$APP_ROOT/Contents/MacOS/XContentAssistant"
cp "$TASK_ROOT/Resources/Info.plist" "$APP_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :XCONTENT_INTERACTIONS_ROOT string $TASK_ROOT/interaction-data" "$APP_ROOT/Contents/Info.plist"
cp "$TASK_ROOT/Resources/AppIcon.icns" "$APP_ROOT/Contents/Resources/AppIcon.icns"
cp "$TASK_ROOT/.build/arm64-apple-macosx/release/XReplyBridge" "$APP_ROOT/Contents/MacOS/XReplyBridge"
codesign --force --deep --sign - "$APP_ROOT"
codesign --verify --deep --strict "$APP_ROOT"
echo "$APP_ROOT"
QA_APP="$TASK_ROOT/qa-dist/X 素材助手 QA.app"
if [ -e "$QA_APP" ]; then mv "$QA_APP" "$TASK_ROOT/qa-dist/QA-$(date +%Y%m%d-%H%M%S).app"; fi
mkdir -p "$QA_APP/Contents/MacOS"
mkdir -p "$QA_APP/Contents/Resources"
cp "$TASK_ROOT/.build/arm64-apple-macosx/release/XContentAssistant" "$QA_APP/Contents/MacOS/XContentAssistant"
cp "$TASK_ROOT/Resources/QA-Info.plist" "$QA_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :XCONTENT_RUNTIME_ROOT string $TASK_ROOT/qa-runtime" "$QA_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :XCONTENT_INTERACTIONS_ROOT string $TASK_ROOT/qa-interactions" "$QA_APP/Contents/Info.plist"
cp "$TASK_ROOT/Resources/AppIcon.icns" "$QA_APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$QA_APP"
codesign --verify --deep --strict "$QA_APP"
