# Why gpuscale works the way it does

This document explains the engineering reasoning behind `gpuscale`. The design
is small, but every choice in it is deliberate. If you only read one doc, read
this one — it will also help you decide whether `gpuscale` is even the right
tool for your problem.

## The problem

> "Upscale a 720p video to 1080p."

That one sentence hides a fork in the road. There are two fundamentally
different operations people mean by "upscale":

1. **Resampling** — compute a larger grid of pixels from the existing ones with
   a reconstruction filter. The detail in the output is the detail that was
   already in the input, resized cleanly. This is deterministic, fast, and
   lossless-in-intent.
2. **Super-resolution ("enhance")** — *invent* plausible new detail that was
   never captured, using a neural network trained on millions of images. This
   is a guess. Sometimes a great guess; sometimes a confident wrong one.

`gpuscale` does **#1**, and does it well. Below is why that is usually the right
call for a simple resolution change, and when it isn't.

## Myth 1: "Multiply by an integer, then downscale, gives better quality"

AI super-resolution models (Real-ESRGAN, ESRGAN, most of the "video enhancer"
family) only upscale by **fixed integer factors** — ×2, ×3, ×4. None of them
natively produces a ×1.5 result. So to turn 720p into 1080p with one of these
models you must:

```
720p ──(AI ×2)──▶ 1440p ──(downscale)──▶ 1080p
       or ×4 ▶ 2880p ──(downscale)──▶ 1080p
```

The appeal is "do it at high resolution, then shrink." But for a target that is
only 1.5× the source, the ×4 path:

- spends enormous compute generating a 2880p frame you immediately throw most of
  away;
- hallucinates fine detail that the downscale then averages back out;
- can introduce model artifacts (over-sharpening, texture invention, temporal
  flicker between frames) that survive the downscale.

The extra scale factor is not free quality — it is mostly wasted work, and what
survives is as likely to be an artifact as a genuine improvement. For a modest
resolution bump, a direct high-quality resample lands in the same place (or
better) for a tiny fraction of the cost.

### The numbers (720p→1080p, 3-minute clip, 4375 frames, M1 Max)

| Approach | Per frame | Full clip | Intermediate disk |
|---|---:|---:|---:|
| Real-ESRGAN `realesrgan-x4plus` (×4, then downscale) | ~11 s | **~13.5 hours** | ~74 GB |
| Real-ESRGAN `realesr-animevideov3` (×2, then downscale) | ~0.35 s | ~25 min | ~21 GB |
| **gpuscale (direct GPU Lanczos)** | ~0.004 s | **~17 s** | 0 |

The ×4 AI path is ~2,800× slower than a direct resample, for a result that — on
a clean 720p source being nudged to 1080p — a viewer will struggle to
distinguish from a good Lanczos resize.

## Myth 2: "The GPU makes the image look better"

It does not. For a **pure resample**, a GPU and a CPU running the **same kernel**
produce essentially identical pixels. The GPU's contribution is **throughput**,
not quality — it evaluates the filter for millions of output pixels in parallel.

So "use the GPU" is a *speed* decision. The *quality* decision is entirely about
the **resampling kernel** and how the pipeline treats color. That is where the
real choices live, below.

## What actually determines quality: the kernel

When you enlarge an image you must invent the in-between pixels. The rule you use
is the *reconstruction filter*. The difference between a cheap and a good filter
is the difference between jagged, aliased edges and smooth ones:

| Filter | Character | Notes |
|---|---|---|
| Nearest-neighbor | Blocky, hard pixel edges | "Pixel mapping" — no anti-aliasing at all. Fast, ugly for photos/video. |
| Bilinear | Soft, slightly blurry | Cheap; mushes detail, mild aliasing on diagonals. |
| **Bicubic** | Balanced, gentle | Good general default; less ringing than Lanczos. `--filter bicubic`. |
| **Lanczos** (windowed sinc) | Sharpest, best edge fidelity | Near-ideal reconstruction; slight ringing possible. **gpuscale default.** |

"Proper anti-aliasing" in an upscale means using a windowed-sinc / cubic
reconstruction (Lanczos/bicubic) instead of nearest or bilinear. Many quick
tools — and naive GPU texture blits — default to nearest or bilinear and leave
visible stair-stepping on edges. `gpuscale` uses Core Image's
`CILanczosScaleTransform` (or `CIBicubicScaleTransform`) so edges are
reconstructed, not stair-stepped.

> Note on terminology: strictly, *anti-aliasing* matters most when **down**scaling
> (removing frequencies that can't be represented at the smaller size). When
> **up**scaling, the same high-quality kernels give you smooth, artifact-free
> *interpolation*. In everyday use "anti-aliased upscale" means exactly this:
> no jaggies, no blockiness — which is what a Lanczos/bicubic kernel delivers.

## Why color management is disabled

Core Image, by default, color-manages: it converts the input into a working
color space, runs the filter, and converts to the output space. If the input's
tagged color space (e.g. BT.709 video) and the output's assumed space (e.g.
sRGB) don't line up perfectly, your colors can shift — washed out or oversaturated.

For a resize we don't *want* a re-grade. We want the output pixel values to be a
faithful, resized version of the input values. So `gpuscale` sets the Core Image
`workingColorSpace` to `NSNull()` and renders with `colorSpace: nil`, which tells
Core Image to operate directly on stored values and skip color conversion. The
resample becomes a faithful passthrough — the colors you put in are the colors
you get out.

## Why the output is video-only (and audio is ffmpeg's job)

`gpuscale` deliberately does one thing: resample the **video** track on the GPU.
It does not touch audio, subtitles, chapters, or exotic containers. Those are
solved problems that `ffmpeg` already does perfectly with a stream copy (no
re-encode, no quality loss, instant). Keeping `gpuscale` focused means:

- less surface area to get wrong (A/V sync, codec matrices, metadata);
- trivial composition into existing `ffmpeg` pipelines;
- the convenience path (`gpuscale-full`) is just a thin wrapper that calls
  `gpuscale` then `ffmpeg -c copy`.

See [FFMPEG.md](FFMPEG.md) for the integration patterns.

## When you should NOT use gpuscale (use AI super-resolution instead)

Reach for a real super-resolution tool when:

- the source is **genuinely low-detail** (old DVD/VHS, heavily compressed,
  small webcam capture) and you want to *reconstruct* detail, not just enlarge it;
- you're upscaling by a large factor (e.g. SD → 4K) where there simply isn't
  enough source detail for interpolation to look sharp;
- you have the **time and disk** (hours and tens of GB — see the table above)
  and can tolerate occasional hallucination/temporal artifacts;
- stylized content where a model's "look" is actually desirable.

This repo ships **both** paths so you can choose: `gpuscale` (resample) and
`realesr-video` (Real-ESRGAN, via `realesrgan-ncnn-vulkan` — GPU, no Python).
`vidscale --method auto` picks resample for ≤ 2× upscales and AI above that.
Commercial **Topaz Video AI** is another strong AI option.

For everything else — a clean source getting a moderate resolution bump, matching
a timeline resolution, meeting an upload spec — a direct, anti-aliased,
color-faithful GPU resample is the correct, honest, and vastly cheaper tool.
That's `gpuscale`.

## Does Real-ESRGAN "invent" detail? Yes — and that's the whole point

A natural question: *why* does AI add detail a resample can't, and does it make
things up?

**It invents. It does not recover.** Detail lost when the video was captured or
encoded at low resolution is gone; no tool retrieves information that was never
stored. Real-ESRGAN instead **synthesizes plausible new detail** from a learned
prior and paints it in. The resampler refuses to invent anything, which is
exactly why it stays soft.

How the invention works: Real-ESRGAN is a GAN trained on millions of
(low-res, high-res) image pairs. It learned, statistically, "when I see this
blurry pattern, the sharp version usually looked like *this*." At inference it
applies that mapping to predict a high-res frame. Because it was trained
*adversarially* — rewarded for output that merely **looks like** a real sharp
image, not for matching any ground truth — it is actively pushed to fabricate
crisp edges and texture.

| | Lanczos resample (`gpuscale`) | Real-ESRGAN (`realesr-video`) |
|---|---|---|
| Inputs to each output pixel | only nearby **real** source pixels | source pixels **+ a learned prior from millions of images** |
| New information added | zero (pure interpolation) | lots (synthesized) |
| Can be *wrong*? | no (but stays soft) | yes (can hallucinate false detail) |

**Does the invention happen "at the ×2/×4 step"?** The scale factor *is* the
invention: it's just how many output pixels the network fills, all from the
prior. Every factor invents — even ×2 (just less, more constrained by real
neighbours). ×4 invents more than ×2: more unknown pixels per real pixel, so
sharper-looking **but** higher risk of hallucinated/garbled detail. That's why
×4-then-downscale is pointless for a small bump (you don't need fabrication) yet
sensible for a big one (you do).

**When the fabrication is trustworthy vs. risky:**
- *Trustworthy-ish:* text, bold edges, geometric shapes — blurry bold text has
  essentially one plausible sharp form, so the guess is almost always right.
- *Risky:* faces, fine textures, small/distant text, licence plates — the model
  confidently invents plausible-but-**false** detail. It looks sharp; it may not
  be true.

So at 360p→1080p you're choosing between **honest-but-soft** (resample) and
**sharp-but-partly-fabricated** (AI). For stylized/commercial footage the
fabrication is almost always flattering; where accuracy matters, treat AI output
as a good-looking guess, not a recovery.

## Implementation summary

1. **Decode** the video track to `BGRA` frames (`AVAssetReader`).
2. For each frame, build a `CIImage` and apply `CILanczosScaleTransform` /
   `CIBicubicScaleTransform`, computing `inputScale` and `inputAspectRatio` so
   the output lands on the exact target W×H from *any* source size.
3. **Render** on the Metal GPU with color management disabled, into a pooled
   `CVPixelBuffer`.
4. **Encode** H.264 at the requested bitrate (`AVAssetWriter`), preserving the
   source presentation timestamps and the track's preferred transform (rotation).
5. (Via `gpuscale-full`) **Mux** the original audio back with `ffmpeg -c copy`.
