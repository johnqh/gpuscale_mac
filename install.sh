#!/usr/bin/env bash
#
# install.sh — build gpuscale (release) and install it, plus the gpuscale-full
# wrapper, into a bin directory on your PATH.
#
# Usage:
#   ./install.sh                 # installs to /usr/local/bin (uses sudo if needed)
#   PREFIX=~/.local ./install.sh # installs to ~/.local/bin (no sudo)
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"

echo "==> gpuscale installer"
echo "    repo:   $REPO_DIR"
echo "    prefix: $PREFIX"

# --- preflight ------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: gpuscale is macOS-only (needs Metal / Core Image / AVFoundation)." >&2
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    echo "error: 'swift' not found. Install Xcode or the Command Line Tools:" >&2
    echo "       xcode-select --install" >&2
    exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "warning: ffmpeg not found. The core 'gpuscale' binary works without it," >&2
    echo "         but 'gpuscale-full' and audio muxing need it:  brew install ffmpeg" >&2
fi

# --- build ----------------------------------------------------------------
echo "==> Building (release)…"
( cd "$REPO_DIR" && swift build -c release )
BIN="$REPO_DIR/.build/release/gpuscale"
[[ -x "$BIN" ]] || { echo "error: build did not produce $BIN" >&2; exit 1; }

# --- install --------------------------------------------------------------
SUDO=""
if [[ ! -d "$BINDIR" ]]; then
    mkdir -p "$BINDIR" 2>/dev/null || SUDO="sudo"
fi
if [[ -n "$SUDO" ]] || { [[ -e "$BINDIR" ]] && [[ ! -w "$BINDIR" ]]; }; then
    SUDO="sudo"
    echo "==> $BINDIR is not writable; using sudo"
fi

$SUDO mkdir -p "$BINDIR"
$SUDO install -m 0755 "$BIN" "$BINDIR/gpuscale"
for w in gpuscale-full realesr-video vidscale; do
    $SUDO install -m 0755 "$REPO_DIR/bin/$w" "$BINDIR/$w"
done

echo "==> Installed:"
echo "    $BINDIR/gpuscale        (core: GPU anti-aliased resampler, video-only)"
echo "    $BINDIR/gpuscale-full   (resample + audio)"
echo "    $BINDIR/realesr-video   (AI super-resolution pipeline)"
echo "    $BINDIR/vidscale        (unified front-end: --method auto|resample|realesrgan)"

# --- optional: Real-ESRGAN engine -----------------------------------------
if command -v realesrgan-ncnn-vulkan >/dev/null 2>&1 \
   || [[ -x "${REALESRGAN_DIR:-$HOME/.local/share/gpuscale/realesrgan}/realesrgan-ncnn-vulkan" ]]; then
    echo "==> Real-ESRGAN engine already present."
else
    echo ""
    echo "note: the AI method (realesr-video / 'vidscale --method realesrgan') needs the"
    echo "      Real-ESRGAN engine. Install it now with:"
    echo "        ./scripts/install-realesrgan.sh"
    if [[ -t 0 ]]; then
        read -r -p "    Install it now? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] && "$REPO_DIR/scripts/install-realesrgan.sh"
    fi
fi

case ":$PATH:" in
    *":$BINDIR:"*) : ;;
    *) echo "note: $BINDIR is not on your PATH. Add to your shell profile:"
       echo "      export PATH=\"$BINDIR:\$PATH\"" ;;
esac

echo "==> Done. Try:  gpuscale --help"
