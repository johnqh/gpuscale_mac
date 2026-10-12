#!/usr/bin/env bash
#
# install-realesrgan.sh — fetch the prebuilt realesrgan-ncnn-vulkan binary
# (and its bundled models) for macOS. Runs on the GPU via Vulkan/MoltenVK,
# needs no Python/PyTorch/CUDA.
#
# Installs to:   ${REALESRGAN_DIR:-$HOME/.local/share/gpuscale/realesrgan}
# The realesr-video pipeline looks there automatically.
#
set -euo pipefail

VERSION_TAG="v0.2.5.0"
ZIP="realesrgan-ncnn-vulkan-20220424-macos.zip"
URL="https://github.com/xinntao/Real-ESRGAN/releases/download/${VERSION_TAG}/${ZIP}"

DEST="${REALESRGAN_DIR:-$HOME/.local/share/gpuscale/realesrgan}"
BIN="$DEST/realesrgan-ncnn-vulkan"

echo "==> Real-ESRGAN (ncnn-vulkan) installer"
echo "    dest: $DEST"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: this installer is for macOS." >&2
    exit 1
fi

if [[ -x "$BIN" ]] && [[ -d "$DEST/models" ]]; then
    echo "==> already installed. Re-run with FORCE=1 to reinstall."
    [[ "${FORCE:-0}" == "1" ]] || { echo "$BIN"; exit 0; }
fi

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> downloading $ZIP"
curl -fL --progress-bar -o "$TMP/$ZIP" "$URL"

echo "==> extracting"
unzip -oq "$TMP/$ZIP" -d "$TMP/unz"
# The archive contains the binary + models/ at its top level.
cp -f "$TMP/unz/realesrgan-ncnn-vulkan" "$BIN"
rm -rf "$DEST/models"
cp -Rf "$TMP/unz/models" "$DEST/models"

echo "==> clearing quarantine + marking executable"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
chmod +x "$BIN"

echo "==> installed models:"
ls "$DEST/models" | sed 's/^/     /'

echo "==> done: $BIN"
echo "    (realesr-video finds this automatically; or set REALESRGAN_DIR / REALESRGAN_BIN)"
