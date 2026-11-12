#!/usr/bin/env bash
# Development harness. Builds the real provider router into a CLI so model
# routing can be verified without the gesture, permissions, or the panel.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJECT_DIR/Sources/IntelligentCursor"

EXTRA_FLAGS=()
if [[ -f "$PROJECT_DIR/work/toolchain-fix/overlay.yaml" ]]; then
    EXTRA_FLAGS+=(-Xfrontend -vfsoverlay -Xfrontend "$PROJECT_DIR/work/toolchain-fix/overlay.yaml")
fi

swiftc -swift-version 5 -target arm64-apple-macosx15.2 -Onone \
    -module-cache-path "$PROJECT_DIR/work/module-cache" \
    "${EXTRA_FLAGS[@]}" \
    "$SRC/Core/Domain.swift" \
    "$SRC/Context/AXRoles.swift" \
    "$SRC/Support/AppConfiguration.swift" \
    "$SRC/Support/Diagnostics.swift" \
    "$SRC/Intelligence/ChatProvider.swift" \
    "$SRC/Intelligence/ResearchIntent.swift" \
    "$SRC/Intelligence/OpenAIProvider.swift" \
    "$SRC/Intelligence/AnthropicProvider.swift" \
    "$SRC/Intelligence/XAIProvider.swift" \
    "$SRC/Intelligence/IntelligenceRouter.swift" \
    "$PROJECT_DIR/work/probe/ask/main.swift" \
    -framework AppKit -framework Security \
    -o "$PROJECT_DIR/work/probe/ask-probe"
echo "$PROJECT_DIR/work/probe/ask-probe"
