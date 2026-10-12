# Real-ESRGAN video pipeline (`realesr-video`)

`realesr-video` upscales video with **AI super-resolution** instead of
resampling. Where `gpuscale` enlarges the detail that already exists,
Real-ESRGAN **reconstructs plausible new detail** using a neural network. Use it
for large upscales from low-resolution sources (360p/480p → 1080p/4K), where a
plain resample would look soft.

> Read [REASONING.md](REASONING.md) first for *when* to use this vs. the
> resampler, and for the honest caveat that AI detail is **synthesized, not
> recovered** — it can hallucinate.

## How it works

```
input ──(ffmpeg)──▶ PNG frames ──(realesrgan-ncnn-vulkan, GPU)──▶ upscaled frames
                                                                        │
          final video ◀──(ffmpeg: reassemble @ src fps + mux audio)─────┘
```

1. **Extract** every video frame to PNG with ffmpeg.
2. **Super-resolve** each frame on the GPU with `realesrgan-ncnn-vulkan`
   (Vulkan/MoltenVK — no Python, no CUDA).
3. **Reassemble** the upscaled frames at the source frame rate, resample to the
   exact target size if needed (Lanczos), and **mux the original audio** back
   (`-c copy`).

## Install the engine

The neural engine is a separate ~50 MB download (binary + models). Not bundled
with this repo:

```bash
./scripts/install-realesrgan.sh
# installs to ~/.local/share/gpuscale/realesrgan (override with REALESRGAN_DIR)
```

`realesr-video` finds it automatically. You can also point at a custom build with
`REALESRGAN_BIN` / `REALESRGAN_MODELS`.

## Usage

```bash
realesr-video <input> <output> [options]
```

| Option | Values | Default | Notes |
|---|---|---|---|
| `--model` | `animevideov3` \| `x4plus` \| `x4plus-anime` | `animevideov3` | See model guide below. |
| `-s, --scale` | `2` \| `3` \| `4` | auto | Native model scale. `animevideov3` only; `x4plus*` force 4. |
| `-H, --height` | px | — | Final height; picks the model scale and resamples to exact size. |
| `-w, --width` | px | — | Final width. |
| `-b, --bitrate` | Mbps | `18` | H.264 bitrate of the reassembled video. |
| `--tmpdir` | dir | mktemp | Where frames are staged (can be **tens of GB**). |
| `--keep-frames` | | off | Keep the staged frames instead of deleting them. |

### Examples

```bash
# 360p -> 1080p — exactly 3x, so no wasteful downscale detour
realesr-video in360.mp4 out1080.mp4 --height 1080

# Force a specific native scale and model
realesr-video in.mp4 out.mp4 --model animevideov3 --scale 2

# Photographic/live-action source, maximum detail (heavier, slower)
realesr-video in.mp4 out.mp4 --model x4plus --height 1080

# Stage frames on a big external disk, keep them for inspection
realesr-video in.mp4 out.mp4 --height 2160 --tmpdir /Volumes/Scratch --keep-frames
```

Or via the unified front-end (auto-selects AI above 2× upscale):

```bash
vidscale in360.mp4 out1080.mp4 --height 1080                 # auto -> realesrgan
vidscale in360.mp4 out1080.mp4 --height 1080 --method realesrgan   # explicit
```

## Choosing a model

| Model | Best for | Scales | Speed | Notes |
|---|---|---|---|---|
| `animevideov3` | **Video** generally; animation, stylized, clean sources | 2/3/4 | **Fast** | Lightweight, video-tuned, supports non-4× factors. Good default. |
| `x4plus` | Photographic / live-action, maximum detail | 4 only | Slow | Heaviest; strongest reconstruction; most hallucination risk. |
| `x4plus-anime` | Anime stills / line art | 4 only | Medium | Tuned for drawn art. |

Tip: for a **1.5× exact** target (e.g. 720p→1080p) you normally wouldn't use AI
at all — use `gpuscale`. For **2×/3×** use `animevideov3` at that exact scale so
there is no downscale afterward.

## Cost: time and disk

Super-resolution is expensive. Rough figures on an Apple M1 Max, per source
frame (input resolution dominates):

| Model / input | ~per frame | 3-min clip (~4300 frames) | Peak disk (frames) |
|---|---:|---:|---:|
| `animevideov3` ×2–×3, 360p in | ~0.3–0.5 s | ~20–35 min | ~10–25 GB |
| `x4plus` ×4, 720p in | ~11 s | **~13 h** | ~70 GB |

- Frames are staged as PNGs on disk; **make sure you have room** (use `--tmpdir`
  to point at a large volume).
- Prefer `animevideov3` and the smallest scale that reaches your target.

## Caveats

- **VFR sources:** the pipeline reassembles at the source's reported frame rate
  as constant frame rate. For variable-frame-rate input, convert first:
  `ffmpeg -i in.mp4 -fps_mode cfr -r 24 cfr.mp4`.
- **Hallucination:** great for edges/text/texture on stylized content; can
  invent false detail on faces, fine print, etc. See REASONING.md.
- **Audio** is stream-copied unchanged; A/V sync relies on CFR output matching
  the source duration.
