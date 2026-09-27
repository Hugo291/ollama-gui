#!/usr/bin/env bash
# Regenerates the Windows icon (packaging/windows/app.ico) and the window and tray
# icon (assets/icon.png) from scripts/make-icon.swift. Runs on macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift scripts/make-icon.swift "$WORK/icon_1024.png" --windows
for size in 16 20 24 32 40 48 64 96 128 256; do
    sips -z "$size" "$size" "$WORK/icon_1024.png" --out "$WORK/icon_$size.png" >/dev/null
done
python3 - "$WORK" packaging/windows/app.ico <<'PY'
import struct, sys, pathlib
work, out = pathlib.Path(sys.argv[1]), sys.argv[2]
sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
images = [(size, (work / f"icon_{size}.png").read_bytes()) for size in sizes]
offset = 6 + 16 * len(images)
entries, data = b"", b""
for size, png in images:
    edge = 0 if size >= 256 else size
    entries += struct.pack("<BBBBHHII", edge, edge, 0, 0, 1, 32, len(png), offset + len(data))
    data += png
pathlib.Path(out).write_bytes(struct.pack("<HHH", 0, 1, len(images)) + entries + data)
PY
cp "$WORK/icon_256.png" assets/icon.png
echo "✓ packaging/windows/app.ico, assets/icon.png"
