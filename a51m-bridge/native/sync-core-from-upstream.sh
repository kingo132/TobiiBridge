#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cp "$ROOT/driver/src/tobiifree_core.zig" "$HERE/tobiifree_core.zig"
cp "$ROOT/driver/src/tlv.zig" "$HERE/tlv.zig"
echo "Synced tobiifree_core.zig and tlv.zig from upstream driver/src/."
