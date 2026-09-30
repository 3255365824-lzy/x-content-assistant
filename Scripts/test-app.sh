#!/bin/sh
set -eu
TASK_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$TASK_ROOT"
export SWIFT_MODULECACHE_PATH="$TASK_ROOT/.swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.swift-module-cache"
export TMPDIR="$TASK_ROOT/.tmp"
mkdir -p "$TMPDIR" "$TASK_ROOT/.cache/swift"
swift build --disable-sandbox --cache-path "$TASK_ROOT/.cache/swift" --config-path "$TASK_ROOT/.cache/config" --security-path "$TASK_ROOT/.cache/security" -c debug
swiftc -swift-version 6 -DAPP_TESTS -parse-as-library -I .build/debug/Modules Sources/XContentAssistant/WorkbenchModel.swift Sources/XContentAssistant/InteractionModel.swift Sources/XContentAssistant/HotMaterialModel.swift Sources/XContentAssistant/OriginalIdeaModel.swift Sources/XContentAssistant/ModelTestHarness.swift .build/debug/XContentAssistantCore.build/*.o -o .build/app-model-tests
.build/app-model-tests
.build/debug/XContentAssistantCoreTestRunner
