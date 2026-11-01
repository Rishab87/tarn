// Renders Tarn's demo video from video/timeline.json (written by build_timeline.py): the whole Mac
// screen as recorded, framed by a slow, eased camera that moves in to read and back out to show the
// Mac; soft dissolves where waiting is skipped; and a quiet end card on the website's pixel tarn.
// The output has no sound; make_video.sh adds the music.
//
//   swiftc -O -o video/render video/render.swift
//   video/render video/timeline.json video/out/raw.mp4          # the whole video
//   video/render video/timeline.json --stills DIR 5.2 9.8 …     # PNG frames at those times, for review
import AppKit
import AVFoundation
import CoreText
import ImageIO
import UniformTypeIdentifiers

struct Seg: Decodable {
    var type: String          // clip | card | black
    var dur: Double           // seconds
    var src: String?          // clip: the screen recording
    var map: [[Double]]?      // clip: [[local s, source s], …]; a repeated local time is a jump
    var cam: [[Double]]?      // clip: [[local s, x, y, zoom], …]; (x, y) = the screen point at the frame's
                              // centre, 0…1 from the top left; zoom 1 = the whole screen
    var frames: String?       // card: folder of PNG frames (the pixel scene), played at 12 fps
    var lines: [String]?      // card: title, then smaller lines
    var fadeIn: Double?       // dissolve from the previous segment over this many seconds
}

struct Timeline: Decodable { var fps: Int; var width: Int; var height: Int; var fadeIn: Double?; var fadeOut: Double?; var segments: [Seg] }

let args = CommandLine.arguments
let tlURL = URL(fileURLWithPath: args[1])
let base = tlURL.deletingLastPathComponent()
let tl = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: tlURL))
let W = CGFloat(tl.width), H = CGFloat(tl.height)
let fps = Double(tl.fps)

// MARK: Timing

func clamp(_ v: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, v)) }
/// Quintic smootherstep: starts and stops with no jolt, so camera moves feel calm.
func smooth(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }

func keyIndex(_ keys: [[Double]], _ t: Double) -> Int {
    var i = 0
    for (j, k) in keys.enumerated() where k[0] <= t + 1e-9 { i = j }
    return i
}

func sourceTime(_ map: [[Double]], _ t: Double) -> Double {
    let i = keyIndex(map, t)
    guard i + 1 < map.count else { return map[i][1] + (t - map[i][0]) }
    let a = map[i], b = map[i + 1]
    return a[1] + (b[1] - a[1]) * clamp((t - a[0]) / max(1e-6, b[0] - a[0]))
}

/// Playback speed at local time t (source seconds per video second).
func speed(_ map: [[Double]], _ t: Double) -> Double {
    let i = keyIndex(map, t)
    guard i + 1 < map.count else { return 1 }
    let a = map[i], b = map[i + 1]
    guard b[0] > a[0] else { return 1 }
    return (b[1] - a[1]) / (b[0] - a[0])
}

func camera(_ cam: [[Double]], _ t: Double) -> (x: Double, y: Double, z: Double) {
    let i = keyIndex(cam, t)
    let a = cam[i]
    guard i + 1 < cam.count else { return (a[1], a[2], a[3]) }
    let b = cam[i + 1]
    let k = smooth(clamp((t - a[0]) / max(1e-6, b[0] - a[0])))
    return (a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k, a[3] + (b[3] - a[3]) * k)
}

// MARK: Drawing

func makeLine(_ text: String, _ font: CTFont, _ color: CGColor) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]))
}
func lineWidth(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }
func serif(_ size: CGFloat) -> CTFont { CTFontCreateWithName("Iowan Old Style" as CFString, size, nil) }
func sans(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont { NSFont.systemFont(ofSize: size, weight: weight) as CTFont }

final class ClipSource {
    let gen: AVAssetImageGenerator
    init(_ url: URL) {
        gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 120)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)
        gen.appliesPreferredTrackTransform = true
    }
    func frame(at seconds: Double) -> CGImage? {
        try? gen.copyCGImage(at: CMTime(seconds: max(0, seconds), preferredTimescale: 6000), actualTime: nil)
    }
}
var sources: [String: ClipSource] = [:]
func source(_ src: String) -> ClipSource {
    if let s = sources[src] { return s }
    let s = ClipSource(base.appendingPathComponent(src)); sources[src] = s; return s
}
var cardFrames: [String: [CGImage]] = [:]
func frames(_ dir: String) -> [CGImage] {
    if let f = cardFrames[dir] { return f }
    let url = base.appendingPathComponent(dir)
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
    let images = names.compactMap { name -> CGImage? in
        guard let src = CGImageSourceCreateWithURL(url.appendingPathComponent(name) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    cardFrames[dir] = images
    return images
}

/// Fills the frame with the part of the screen the camera looks at.
func drawFootage(_ ctx: CGContext, _ img: CGImage, x: Double, y: Double, z: Double) {
    let iw = CGFloat(img.width), ih = CGFloat(img.height)
    let cw = iw / CGFloat(max(1, z)), ch = cw * H / W
    let cx = min(max(CGFloat(x) * iw, cw / 2), iw - cw / 2)
    let cy = min(max(CGFloat(y) * ih, ch / 2), ih - ch / 2)
    let s = W / cw
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: -(cx - cw / 2) * s, y: H - (ih - (cy - ch / 2)) * s, width: iw * s, height: ih * s))
}

/// "sped up", small, in the corner, whenever the footage runs faster than real time.
func drawSpedUp(_ ctx: CGContext, alpha: CGFloat) {
    guard alpha > 0.01 else { return }
    let l = makeLine("sped up", sans(20, .medium), CGColor(gray: 1, alpha: alpha))
    var ascent: CGFloat = 0, descent: CGFloat = 0
    _ = CTLineGetTypographicBounds(l, &ascent, &descent, nil)
    let rect = CGRect(x: W - 36 - lineWidth(l) - 28, y: 30, width: lineWidth(l) + 28, height: 34)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.55 * alpha))
    ctx.fillPath()
    ctx.textPosition = CGPoint(x: rect.minX + 14, y: rect.midY - (ascent - descent) / 2)
    CTLineDraw(l, ctx)
    ctx.restoreGState()
}

func drawSegment(_ ctx: CGContext, _ seg: Seg, local: Double) {
    switch seg.type {
    case "clip":
        guard let src = seg.src, let map = seg.map, let cam = seg.cam else { return }
        if let img = source(src).frame(at: sourceTime(map, local)) {
            let c = camera(cam, local)
            drawFootage(ctx, img, x: c.x, y: c.y, z: c.z)
        }
        // Fade the tag in and out over about a quarter second around sped-up stretches.
        let fast = { (t: Double) in speed(map, t) > 1.5 ? 1.0 : 0.0 }
        let a = (fast(local) + fast(local - 0.12) + fast(local + 0.12) + fast(local - 0.24) + fast(local + 0.24)) / 5
        drawSpedUp(ctx, alpha: CGFloat(a))
    case "card":
        if let dir = seg.frames {
            let f = frames(dir)
            if !f.isEmpty {
                ctx.interpolationQuality = .none
                ctx.draw(f[Int(local * 12) % f.count], in: CGRect(x: 0, y: 0, width: W, height: H))
            }
        }
        let lines = seg.lines ?? []
        let ink = { (a: Double) in CGColor(srgbRed: 0.97, green: 0.96, blue: 0.93, alpha: CGFloat(a)) }
        if let title = lines.first {
            let l = makeLine(title, serif(132), ink(smooth(clamp((local - 0.3) / 1.2))))
            ctx.textPosition = CGPoint(x: W / 2 - lineWidth(l) / 2, y: H * 0.64)
            CTLineDraw(l, ctx)
        }
        for (i, text) in lines.dropFirst().enumerated() {
            let k = smooth(clamp((local - 0.8 - Double(i) * 0.25) / 1.2))
            let l = i == 0 ? makeLine(text, serif(40), ink(k * 0.9)) : makeLine(text, sans(22, .regular), ink(k * 0.62))
            ctx.textPosition = CGPoint(x: W / 2 - lineWidth(l) / 2, y: i == 0 ? H * 0.64 - 74 : 44)
            CTLineDraw(l, ctx)
        }
    default:
        break
    }
}

// MARK: Frames

let segs = tl.segments
let starts = segs.indices.map { i in segs[..<i].reduce(0) { $0 + $1.dur } }
let total = segs.reduce(0) { $0 + $1.dur }

func render(_ ctx: CGContext, at t: Double) {
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    guard let i = starts.lastIndex(where: { $0 <= t + 1e-9 }) else { return }
    let seg = segs[i], local = t - starts[i]
    if i > 0, let fade = seg.fadeIn, fade > 0, local < fade {
        // Dissolve: the previous segment keeps playing underneath while this one fades in.
        drawSegment(ctx, segs[i - 1], local: segs[i - 1].dur + local)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(smooth(local / fade)))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawSegment(ctx, seg, local: local)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    } else {
        drawSegment(ctx, seg, local: local)
    }
    let fadeIn = tl.fadeIn ?? 0, fadeOut = tl.fadeOut ?? 0
    var black = 0.0
    if fadeIn > 0, t < fadeIn { black = 1 - smooth(t / fadeIn) }
    if fadeOut > 0, t > total - fadeOut { black = max(black, smooth((t - (total - fadeOut)) / fadeOut)) }
    if black > 0 {
        ctx.setFillColor(CGColor(gray: 0, alpha: black))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    }
}

func bitmap() -> CGContext {
    CGContext(data: nil, width: tl.width, height: tl.height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

if args.count > 2, args[2] == "--stills" {
    let dir = URL(fileURLWithPath: args[3])
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for arg in args.dropFirst(4) {
        guard let t = Double(arg) else { continue }
        let ctx = bitmap()
        render(ctx, at: t)
        let url = dir.appendingPathComponent(String(format: "%06.2f.png", t))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
    exit(0)
}

let outURL = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: outURL)
try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: tl.width, AVVideoHeightKey: tl.height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: tl.width, kCVPixelBufferHeightKey as String: tl.height,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
let frameCount = Int((total * fps).rounded())
for f in 0..<frameCount {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    guard let buffer = pb else { fatalError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: tl.width, height: tl.height, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    render(ctx, at: Double(f) / fps)
    CVPixelBufferUnlockBaseAddress(buffer, [])
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(tl.fps)))
    if f % 600 == 0 { print("frame \(f)/\(frameCount)") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print("wrote \(outURL.path) (\(String(format: "%.2f", total)) s)")
