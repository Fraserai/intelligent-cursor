#!/usr/bin/env bash
# Development harness. Builds the real context engine into a CLI so the semantic
# layer can be exercised without the mouse gesture or the panel.
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
    "$SRC/Support/CoordinateSpace.swift" \
    "$SRC/Support/Diagnostics.swift" \
    "$SRC/Context/AXRoles.swift" \
    "$SRC/Context/AccessibilitySemanticResolver.swift" \
    "$SRC/Context/ContextAcquisitionEngine.swift" \
    "$SRC/Context/ScreenCaptureAdapter.swift" \
    "$SRC/Context/OCRAdapter.swift" \
    "$SRC/Context/FileContextExtractor.swift" \
    "$PROJECT_DIR/work/probe/context/main.swift" \
    -framework AppKit -framework ApplicationServices -framework PDFKit \
    -framework ScreenCaptureKit -framework UniformTypeIdentifiers -framework Vision \
    -o "$PROJECT_DIR/work/probe/context-probe"
echo "$PROJECT_DIR/work/probe/context-probe"
