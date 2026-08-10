#!/bin/bash
# Cross-compile the Dropship agent for linux/amd64 and linux/arm64.
# Output: ../build/agents/agent-linux-amd64, agent-linux-arm64
set -euo pipefail

cd "$(dirname "$0")"

OUT_DIR="../build/agents"
mkdir -p "$OUT_DIR"

LDFLAGS="-s -w"

for ARCH in amd64 arm64; do
    echo "Building linux/$ARCH..."
    CGO_ENABLED=0 GOOS=linux GOARCH=$ARCH go build \
        -ldflags="$LDFLAGS" \
        -o "$OUT_DIR/agent-linux-$ARCH" \
        .
    SIZE=$(du -h "$OUT_DIR/agent-linux-$ARCH" | cut -f1)
    echo "  -> agent-linux-$ARCH ($SIZE)"
done

echo "Done."
