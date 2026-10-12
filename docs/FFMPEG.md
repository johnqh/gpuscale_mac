# Integrating gpuscale with ffmpeg

`gpuscale` is a focused GPU **video** resampler. `ffmpeg` is the Swiss-army knife
for everything around it — demuxing, muxing, audio, subtitles, containers,
bitrate control, and batch work. They compose well. This doc shows the common
patterns.

## The division of labor

```
            ┌──────────────┐        ┌───────────────────────────┐
 input ───▶ │   gpuscale   │ ─────▶ │          ffmpeg           │ ───▶ final
            │ GPU resample │ video  │ mux audio / subs / format │
            │  (H.264)     │ only   │   (stream copy = instant) │
            └──────────────┘        └───────────────────────────┘
```

`gpuscale` emits a video-only MP4. `ffmpeg` carries across whatever else you need
with `-c copy` (no re-encode, no quality loss). `gpuscale-full` is just this
pipeline wrapped in one command.

The **AI pipeline (`realesr-video`) also rides on ffmpeg**: it uses ffmpeg to
extract frames to PNG, hands them to `realesrgan-ncnn-vulkan`, then uses ffmpeg
again to reassemble at the source frame rate and mux the original audio. So every
ffmpeg pattern below applies to both methods' output.

## 1. Carry the original audio (the common case)

What `gpuscale-full` does under the hood:

```bash
gpuscale in.mp4 video.mp4 --height 1080
ffmpeg -i video.mp4 -i in.mp4 \
       -map 0:v:0 -map 1:a:0 \
       -c copy -movflags +faststart \
       final.mp4
```

- `-map 0:v:0` — video from the gpuscale output.
- `-map 1:a:0` — audio from the original, untouched.
- `-c copy` — stream copy, so audio is bit-for-bit identical and the step is instant.
- `-movflags +faststart` — moves the MP4 index to the front for web/streaming.

## 2. Carry audio + subtitles + all audio tracks

```bash
ffmpeg -i video.mp4 -i in.mp4 \
       -map 0:v:0 -map 1:a -map 1:s? \
       -c copy -c:s mov_text \
       final.mp4
```

`-map 1:a` takes *all* audio tracks; `-map 1:s?` takes subtitles if present
(the `?` makes it optional so the command doesn't fail when there are none).

## 3. Re-encode audio (e.g. normalize to AAC 192k)

```bash
ffmpeg -i video.mp4 -i in.mp4 \
       -map 0:v:0 -map 1:a:0 \
       -c:v copy -c:a aac -b:a 192k \
       final.mp4
```

## 4. Control video size/quality with gpuscale flags

Bitrate and kernel live on the `gpuscale` side:

```bash
# visually-lossless-ish 1080p
gpuscale in.mp4 v.mp4 --height 1080 --bitrate 18

# smaller file
gpuscale in.mp4 v.mp4 --height 1080 --bitrate 10

# softer kernel (less ringing on noisy sources)
gpuscale in.mp4 v.mp4 --height 1080 --filter bicubic
```

Want a smaller file *after* scaling without re-running the GPU pass? Re-encode
just the video with ffmpeg (CRF gives you quality-targeted sizing):

```bash
ffmpeg -i video.mp4 -c:v libx264 -crf 20 -preset slow -an video_small.mp4
```

## 5. Different container / codec (HEVC, WebM, ProRes…)

`gpuscale` outputs H.264/MP4. Transcode with ffmpeg if you need something else:

```bash
# HEVC/H.265 in MP4 (VideoToolbox hardware encoder on macOS)
ffmpeg -i video.mp4 -i in.mp4 -map 0:v:0 -map 1:a:0 \
       -c:v hevc_videotoolbox -b:v 12M -tag:v hvc1 -c:a copy final_hevc.mp4

# VP9/Opus in WebM
ffmpeg -i video.mp4 -i in.mp4 -map 0:v:0 -map 1:a:0 \
       -c:v libvpx-vp9 -b:v 0 -crf 30 -c:a libopus final.webm
```

## 6. Batch processing a folder

```bash
#!/usr/bin/env bash
set -euo pipefail
mkdir -p out
for f in in/*.mp4; do
    base="$(basename "$f")"
    gpuscale-full "$f" "out/${base%.mp4}_1080p.mp4" --height 1080 --bitrate 16
done
```

## 7. Extract a frame to compare quality

```bash
# a frame at 30s from source vs. upscaled, same crop, for A/B inspection
ffmpeg -ss 30 -i in.mp4         -frames:v 1 -vf "crop=760:380:760:70" src_crop.png
ffmpeg -ss 30 -i final.mp4      -frames:v 1 -vf "crop=1140:570:1140:105" out_crop.png
```

---

## How gpuscale compares to ffmpeg's own scalers

ffmpeg can of course resize video itself. When should you use which?

### `ffmpeg -vf scale` (CPU)

```bash
ffmpeg -i in.mp4 -vf "scale=1920:1080:flags=lanczos" -c:v libx264 -crf 18 out.mp4
```

- **Also a high-quality Lanczos resample** — `flags=lanczos` gives proper
  anti-aliasing, equivalent in *quality* to gpuscale's Lanczos.
- Runs on the **CPU**. Fine for one-off jobs; slower than the GPU for large
  batches or high resolutions.
- If you just want a correct resize and don't care about using the GPU, this is
  a perfectly good answer and needs no extra tooling.

`gpuscale`'s advantages over CPU `scale`: GPU throughput (hundreds of fps),
Core Image's kernels with color-management control, and a single-purpose CLI.
Its cost: it's macOS-only and video-only.

### `ffmpeg -vf scale_vt` / `libplacebo` (GPU)

- `scale_vt` (VideoToolbox) exists but, depending on how your ffmpeg was built,
  the hardware-frame filter chain can be incomplete — on Homebrew's default
  `ffmpeg` formula the `scale_vt` / `hwdownload` path commonly errors out
  (`Function not implemented` / `Invalid argument`).
- `libplacebo` offers excellent GPU scaling (and edge-directed shaders) but
  requires an ffmpeg built `--enable-libplacebo --enable-vulkan`, which the
  stock Homebrew bottle does **not** include.

`gpuscale` sidesteps both: it talks directly to Metal/Core Image, so GPU scaling
works out of the box on any Metal-capable Mac without a custom ffmpeg build.

### Rule of thumb

| You want… | Use |
|---|---|
| A correct resize, one-off, don't care about GPU | `ffmpeg -vf scale=…:flags=lanczos` |
| GPU speed for batches / high res, no custom ffmpeg build | **gpuscale** |
| To *reconstruct* detail from a low-res source | Real-ESRGAN / Topaz (see REASONING.md) |
