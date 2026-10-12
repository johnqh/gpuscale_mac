#!/usr/bin/env bash
#
# install.sh — build gpuscale and install all commands plus their dependencies.
#
# Installs:
#   - dependencies:  ffmpeg (via Homebrew) and the Real-ESRGAN GPU engine
#   - commands:      gpuscale, gpuscale-full, realesr-video, vidscale
#
# Usage:
#   ./install.sh                  # install deps + build + install to /usr/local/bin
#   PREFIX=~/.local ./install.sh  # install to ~/.local/bin (no sudo)
#   ./install.sh --no-deps        # skip ffmpeg / Real-ESRGAN (just build + install commands)
#   ./install.sh --no-realesrgan  # install ffmpeg but skip the Real-ESRGAN engine
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"

WITH_DEPS=1
WITH_REALESRGAN=1
for arg in "$@"; do
    case "$arg" in
        --no-deps)        WITH_DEPS=0;;
        --no-realesrgan)  WITH_REALESRGAN=0;;
        -h|--help)        sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *) echo "unknown argument: $arg (try --help)" >&2; exit 2;;
    esac
done

echo "==> gpuscale installer"
echo "    repo:   $REPO_DIR"
echo "    prefix: $PREFIX"

# --- platform -------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: gpuscale is macOS-only (needs Metal / Core Image / AVFoundation)." >&2
    exit 1
fi

# --- dependency helpers ---------------------------------------------------
ensure_homebrew() {
    if command -v brew >/dev/null 2>&1; then return 0; fi
    echo "error: Homebrew is required to auto-install dependencies but was not found." >&2
    echo "       Install it from https://brew.sh then re-run, or use --no-deps and" >&2
    echo "       install ffmpeg yourself." >&2
    return 1
}

ensure_swift() {
    if command -v swift >/dev/null 2>&1; then return 0; fi
    echo "==> Swift toolchain not found; launching the Command Line Tools installer…"
    xcode-select --install 2>/dev/null || true
    echo "error: Swift is required to build gpuscale." >&2
    echo "       Finish the 'Command Line Tools' installation that just opened" >&2
    echo "       (or install Xcode), then re-run ./install.sh." >&2
    exit 1
}

ensure_ffmpeg() {
    if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
        echo "==> ffmpeg already installed ($(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}'))."
        return 0
    fi
    echo "==> Installing ffmpeg via Homebrew…"
    ensure_homebrew || exit 1
    brew install ffmpeg
}

ensure_realesrgan() {
    local dir="${REALESRGAN_DIR:-$HOME/.local/share/gpuscale/realesrgan}"
    if command -v realesrgan-ncnn-vulkan >/dev/null 2>&1 || [[ -x "$dir/realesrgan-ncnn-vulkan" ]]; then
        echo "==> Real-ESRGAN engine already installed."
        return 0
    fi
    echo "==> Installing Real-ESRGAN GPU engine…"
    "$REPO_DIR/scripts/install-realesrgan.sh"
}

# --- install dependencies -------------------------------------------------
ensure_swift
if [[ "$WITH_DEPS" == "1" ]]; then
    ensure_ffmpeg
    [[ "$WITH_REALESRGAN" == "1" ]] && ensure_realesrgan
else
    echo "==> --no-deps: skipping ffmpeg / Real-ESRGAN."
    command -v ffmpeg >/dev/null 2>&1 || echo "    (warning: ffmpeg not found; audio muxing and the AI pipeline need it)"
fi

# --- build ----------------------------------------------------------------
echo "==> Building (release)…"
( cd "$REPO_DIR" && swift build -c release )
BIN="$REPO_DIR/.build/release/gpuscale"
[[ -x "$BIN" ]] || { echo "error: build did not produce $BIN" >&2; exit 1; }

# --- install commands -----------------------------------------------------
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

case ":$PATH:" in
    *":$BINDIR:"*) : ;;
    *) echo "note: $BINDIR is not on your PATH. Add to your shell profile:"
       echo "      export PATH=\"$BINDIR:\$PATH\"" ;;
esac

echo "==> Done. Try:  vidscale --help"
