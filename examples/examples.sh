#!/usr/bin/env bash
#
# examples.sh — runnable examples for gpuscale.
#
#   ./examples/examples.sh <input.mp4>   # run a few example resizes on your file
#   ./examples/examples.sh --self-test   # synthesize a clip and verify gpuscale
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPUSCALE="$REPO_DIR/.build/release/gpuscale"
[[ -x "$GPUSCALE" ]] || GPUSCALE="$(command -v gpuscale || true)"
[[ -n "$GPUSCALE" && -x "$GPUSCALE" ]] || { echo "build first: swift build -c release" >&2; exit 1; }

probe() { ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$1"; }

if [[ "${1:-}" == "--self-test" ]]; then
    command -v ffmpeg  >/dev/null || { echo "self-test needs ffmpeg" >&2; exit 1; }
    command -v ffprobe >/dev/null || { echo "self-test needs ffprobe" >&2; exit 1; }
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    echo "==> synthesizing 3s 1280x720 test clip"
    ffmpeg -v error -y -f lavfi -i testsrc=size=1280x720:rate=24:duration=3 \
           -pix_fmt yuv420p "$TMP/src.mp4"

    echo "==> gpuscale --height 1080"
    "$GPUSCALE" "$TMP/src.mp4" "$TMP/out1080.mp4" --height 1080 -b 12
    got="$(probe "$TMP/out1080.mp4")"
    [[ "$got" == "1920,1080" ]] || { echo "FAIL: expected 1920,1080 got $got" >&2; exit 1; }
    echo "    ok: $got"

    echo "==> gpuscale --scale 1.5 --filter bicubic"
    "$GPUSCALE" "$TMP/src.mp4" "$TMP/out15.mp4" --scale 1.5 --filter bicubic -b 12
    got="$(probe "$TMP/out15.mp4")"
    [[ "$got" == "1920,1080" ]] || { echo "FAIL: expected 1920,1080 got $got" >&2; exit 1; }
    echo "    ok: $got"

    echo "==> gpuscale --width 640 (downscale, aspect auto)"
    "$GPUSCALE" "$TMP/src.mp4" "$TMP/out640.mp4" --width 640 -b 6
    got="$(probe "$TMP/out640.mp4")"
    [[ "$got" == "640,360" ]] || { echo "FAIL: expected 640,360 got $got" >&2; exit 1; }
    echo "    ok: $got"

    echo "SELF-TEST PASSED"
    exit 0
fi

IN="${1:-}"
[[ -n "$IN" && -f "$IN" ]] || { echo "usage: $0 <input.mp4> | --self-test" >&2; exit 2; }
OUTDIR="./gpuscale_examples_out"
mkdir -p "$OUTDIR"

echo "==> $IN  (source: $(probe "$IN"))"
set -x
"$GPUSCALE" "$IN" "$OUTDIR/01_height1080_lanczos.mp4" --height 1080 --bitrate 18
"$GPUSCALE" "$IN" "$OUTDIR/02_scale1.5_bicubic.mp4"   --scale 1.5 --filter bicubic
"$GPUSCALE" "$IN" "$OUTDIR/03_4k_40mbps.mp4"          --width 3840 --bitrate 40
set +x
echo "==> wrote examples to $OUTDIR/ (video-only; use gpuscale-full for audio)"
