// gpuscale — GPU (Metal / Core Image) anti-aliased video resampler for macOS.
//
// Resamples a video from its source resolution to a target resolution in a
// single direct step, using a high-quality windowed-sinc (Lanczos) or bicubic
// kernel running on the GPU. No integer-multiply-then-downscale detour, no
// AI detail hallucination — just a faithful, properly anti-aliased resize.
//
// The output is a video-only H.264 file. Audio is intentionally left to ffmpeg
// (see `gpuscale-full` and docs/FFMPEG.md) so this stays a focused, composable
// building block.
//
// See docs/REASONING.md for *why* it is built this way.

import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Metal

let VERSION = "1.0.0"

func logErr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func die(_ s: String) -> Never { logErr("gpuscale: error: " + s); exit(1) }

let usage = """
gpuscale \(VERSION) — GPU anti-aliased video resampler for macOS (Metal/Core Image)

USAGE:
  gpuscale <input> <output> [options]

OUTPUT SIZE (choose one; dimensions round to even numbers for H.264):
  -w, --width  <px>       target width  (height auto-derived if --height omitted)
  -H, --height <px>       target height (width  auto-derived if --width  omitted)
  -s, --scale  <factor>   multiply both source dimensions by <factor> (e.g. 1.5)

OPTIONS:
  -b, --bitrate <Mbps>    average H.264 bitrate in Mbps          (default: 18)
  -f, --filter  <name>    resampling kernel: lanczos | bicubic   (default: lanczos)
      --sharpen <amount>  post-resample luminance sharpen 0–2    (default: 0 = off)
  -h, --help              show this help and exit
  -V, --version           print version and exit

EXAMPLES:
  gpuscale in.mp4 out.mp4 --height 1080           # 720p -> 1080p, keep aspect
  gpuscale in.mp4 out.mp4 -s 1.5                  # scale both dims by 1.5x
  gpuscale in.mp4 out.mp4 -w 3840 -b 40           # 4K, 40 Mbps
  gpuscale in.mp4 out.mp4 -H 1080 -f bicubic      # softer kernel, less ringing

NOTES:
  * Output is VIDEO-ONLY. To carry the original audio, use `gpuscale-full`,
    or mux with ffmpeg:
      ffmpeg -i out.mp4 -i in.mp4 -map 0:v:0 -map 1:a:0 -c copy final.mp4
  * Color management is disabled so the resample is a faithful passthrough
    (no BT.709/sRGB shift). See docs/REASONING.md.
"""

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

var positional: [String] = []
var optWidth: Int?
var optHeight: Int?
var optScale: Double?
var optBitrate: Double = 18
var optFilter = "lanczos"
var optSharpen: Double = 0

var i = 1
let argv = CommandLine.arguments
func nextValue(_ flag: String) -> String {
    i += 1
    guard i < argv.count else { die("missing value for \(flag)") }
    return argv[i]
}
func intValue(_ flag: String) -> Int {
    let s = nextValue(flag)
    guard let v = Int(s) else { die("invalid integer for \(flag): \(s)") }
    return v
}
func doubleValue(_ flag: String) -> Double {
    let s = nextValue(flag)
    guard let v = Double(s) else { die("invalid number for \(flag): \(s)") }
    return v
}
while i < argv.count {
    let a = argv[i]
    switch a {
    case "-h", "--help":    print(usage); exit(0)
    case "-V", "--version": print("gpuscale \(VERSION)"); exit(0)
    case "-w", "--width":   optWidth = intValue(a)
    case "-H", "--height":  optHeight = intValue(a)
    case "-s", "--scale":   optScale = doubleValue(a)
    case "-b", "--bitrate": optBitrate = doubleValue(a)
    case "-f", "--filter":  optFilter = nextValue(a).lowercased()
    case "--sharpen":       optSharpen = doubleValue(a)
    default:
        if a.hasPrefix("-") { die("unknown option \(a) (try --help)") }
        positional.append(a)
    }
    i += 1
}

guard positional.count == 2 else {
    logErr(usage)
    die("expected <input> and <output> (got \(positional.count) positional args)")
}
let inURL = URL(fileURLWithPath: positional[0])
let outURL = URL(fileURLWithPath: positional[1])
guard ["lanczos", "bicubic"].contains(optFilter) else { die("--filter must be lanczos or bicubic") }
guard optWidth != nil || optHeight != nil || optScale != nil else {
    die("specify output size with --width, --height, and/or --scale (try --help)")
}
guard FileManager.default.fileExists(atPath: inURL.path) else { die("input not found: \(inURL.path)") }

// ---------------------------------------------------------------------------
// GPU / Core Image setup
// ---------------------------------------------------------------------------

guard let device = MTLCreateSystemDefaultDevice() else { die("no Metal device available") }
// workingColorSpace = NSNull() disables Core Image color management: the kernel
// operates directly on stored pixel values, so no color space conversion shifts
// the colors. We want a faithful resample, not a re-grade.
let ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])

// ---------------------------------------------------------------------------
// Load source, compute target size
// ---------------------------------------------------------------------------

let asset = AVURLAsset(url: inURL)
let vtracks = try await asset.loadTracks(withMediaType: .video)
guard let vtrack = vtracks.first else { die("no video track in input") }
let naturalSize = try await vtrack.load(.naturalSize)
let transform = try await vtrack.load(.preferredTransform)
let nominalFPS = try await vtrack.load(.nominalFrameRate)
let srcW = Double(naturalSize.width)
let srcH = Double(naturalSize.height)
guard srcW > 0, srcH > 0 else { die("could not read source dimensions") }

func evenRound(_ x: Double) -> Int { let n = Int((x / 2.0).rounded()) * 2; return max(2, n) }

var outW: Int
var outH: Int
if let s = optScale {
    outW = evenRound(srcW * s)
    outH = evenRound(srcH * s)
} else if let w = optWidth, let h = optHeight {
    outW = evenRound(Double(w)); outH = evenRound(Double(h))
} else if let w = optWidth {
    outW = evenRound(Double(w)); outH = evenRound(srcH * Double(w) / srcW)
} else {
    let h = optHeight!; outH = evenRound(Double(h)); outW = evenRound(srcW * Double(h) / srcH)
}

logErr("gpuscale \(VERSION): \(Int(srcW))x\(Int(srcH)) -> \(outW)x\(outH)  "
     + "filter=\(optFilter) bitrate=\(optBitrate)Mbps sharpen=\(optSharpen) ~\(String(format: "%.3f", nominalFPS))fps")

// ---------------------------------------------------------------------------
// Reader (decode to BGRA) and Writer (encode H.264)
// ---------------------------------------------------------------------------

try? FileManager.default.removeItem(at: outURL)

let reader = try AVAssetReader(asset: asset)
let readerOutput = AVAssetReaderTrackOutput(track: vtrack, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
])
readerOutput.alwaysCopiesSampleData = false
reader.add(readerOutput)

let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: outW,
    AVVideoHeightKey: outH,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: Int(optBitrate * 1_000_000),
        AVVideoMaxKeyFrameIntervalKey: 48,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoAllowFrameReorderingKey: true
    ]
])
writerInput.expectsMediaDataInRealTime = false
writerInput.transform = transform
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: outW,
    kCVPixelBufferHeightKey as String: outH,
    kCVPixelBufferMetalCompatibilityKey as String: true
])
writer.add(writerInput)

guard reader.startReading() else { die("reader failed to start: \(String(describing: reader.error))") }
guard writer.startWriting() else { die("writer failed to start: \(String(describing: writer.error))") }

// CILanczosScaleTransform / CIBicubicScaleTransform scale by `inputScale`
// (vertical) and stretch horizontally by `inputAspectRatio`. To hit an exact
// WxH target from any source we set:
//   scale       = outH / srcH
//   aspectRatio = (outW/srcW) / (outH/srcH)
// which yields width = outW, height = outH exactly.
let vScale = Double(outH) / srcH
let aspect = (Double(outW) / srcW) / vScale
let filterName = optFilter == "bicubic" ? "CIBicubicScaleTransform" : "CILanczosScaleTransform"
let dstRect = CGRect(x: 0, y: 0, width: outW, height: outH)

var started = false
var count = 0
let start = Date()

while let sample = readerOutput.copyNextSampleBuffer() {
    guard let srcBuf = CMSampleBufferGetImageBuffer(sample) else { continue }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    if !started { writer.startSession(atSourceTime: pts); started = true }

    var image = CIImage(cvImageBuffer: srcBuf)
    guard let scaler = CIFilter(name: filterName) else { die("CoreImage filter \(filterName) unavailable") }
    scaler.setValue(image, forKey: kCIInputImageKey)
    scaler.setValue(vScale, forKey: kCIInputScaleKey)
    scaler.setValue(aspect, forKey: kCIInputAspectRatioKey)
    guard let scaled = scaler.outputImage else { die("scaler produced no image") }
    image = scaled

    if optSharpen > 0, let sharp = CIFilter(name: "CISharpenLuminance") {
        sharp.setValue(image, forKey: kCIInputImageKey)
        sharp.setValue(optSharpen, forKey: "inputSharpness")
        if let s = sharp.outputImage { image = s }
    }
    image = image.cropped(to: dstRect)

    guard let pool = adaptor.pixelBufferPool else { die("no pixel buffer pool (writer not ready)") }
    var pbOut: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else {
        die("failed to allocate output pixel buffer")
    }
    ciContext.render(image, to: pb, bounds: dstRect, colorSpace: nil)

    while !writerInput.isReadyForMoreMediaData { usleep(500) }
    if !adaptor.append(pb, withPresentationTime: pts) {
        die("append failed at frame \(count): \(String(describing: writer.error))")
    }

    count += 1
    if count % 250 == 0 {
        let fps = Double(count) / Date().timeIntervalSince(start)
        logErr(String(format: "  %5d frames  (%.1f fps)", count, fps))
    }
}

if reader.status == .failed { die("reader error: \(String(describing: reader.error))") }

writerInput.markAsFinished()
await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
    writer.finishWriting { cont.resume() }
}
if writer.status != .completed { die("writer did not complete: \(String(describing: writer.error))") }

let dt = Date().timeIntervalSince(start)
logErr(String(format: "gpuscale: done — %d frames in %.1fs (%.1f fps) -> %@", count, dt, Double(count) / dt, outURL.path))
