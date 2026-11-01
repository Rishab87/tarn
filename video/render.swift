// Renders Tarn's launch video from video/timeline.json (written by build_timeline.py).
// Hard cuts on the beat, full-bleed app footage framed by an eased camera, and big condensed type
// that snaps up into place. The output has no sound; make_video.sh adds the soundtrack.
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
    var type: String          // big | black | clip | end
    var dur: Double           // seconds
    var lines: [String]?      // big, end
    var src: String?          // clip
    var map: [[Double]]?      // clip: [[local s, source s], …]; repeating a local time makes a jump cut
    var cam: [[Double]]?      // clip: [[local s, x, y, zoom], …]; (x, y) = the point of the window at the frame's
                              // centre, 0…1 from the top left; zoom 1 = the window's full width
    var drift: Double?        // zoom gained over the segment: a slow push that keeps holds alive
    var caption: String?      // clip
    var captionUntil: Double? // clip: hide the caption from this local time on
    var note: Bool?           // clip: shows "sped up"
    var instant: Bool?        // big: already in place on its first frame (the video's first frame is its thumbnail)
}

struct Timeline: Decodable { var fps: Int; var width: Int; var height: Int; var segments: [Seg] }

let args = CommandLine.arguments
let tlURL = URL(fileURLWithPath: args[1])
let base = tlURL.deletingLastPathComponent()
let tl = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: tlURL))
let W = CGFloat(tl.width), H = CGFloat(tl.height)
let fps = Double(tl.fps)

// MARK: Timing helpers

func clamp(_ v: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, v)) }
func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
func easeOutExpo(_ t: Double) -> Double { t >= 1 ? 1 : 1 - pow(2, -10 * t) }

/// The last key at or before `t`. Keys are sorted by time; two keys at the same time mean a jump.
func keyIndex(_ keys: [[Double]], _ t: Double) -> Int {
    var i = 0
    for (j, k) in keys.enumerated() where k[0] <= t + 1e-9 { i = j }
    return i
}

/// Source time at local time `t`: linear between keys, so each stretch plays at one speed.
func sourceTime(_ map: [[Double]], _ t: Double) -> Double {
    let i = keyIndex(map, t)
    guard i + 1 < map.count else { return map[i][1] + (t - map[i][0]) }
    let a = map[i], b = map[i + 1]
    return a[1] + (b[1] - a[1]) * clamp((t - a[0]) / max(1e-6, b[0] - a[0]))
}

/// Camera at local time `t`: equal keys hold, different keys move with an ease in and out.
func camera(_ cam: [[Double]], _ t: Double) -> (x: Double, y: Double, z: Double) {
    let i = keyIndex(cam, t)
    let a = cam[i]
    guard i + 1 < cam.count else { return (a[1], a[2], a[3]) }
    let b = cam[i + 1]
    let k = easeInOut(clamp((t - a[0]) / max(1e-6, b[0] - a[0])))
    return (a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k, a[3] + (b[3] - a[3]) * k)
}

// MARK: Type

let white = CGColor(gray: 1, alpha: 1)
let black = CGColor(gray: 0, alpha: 1)
let condensed = "HelveticaNeue-CondensedBlack"

func ctFont(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }
func sysFont(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont { NSFont.systemFont(ofSize: size, weight: weight) as CTFont }

func makeLine(_ text: String, _ font: CTFont, _ color: CGColor, kern: CGFloat = 0) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTKernAttributeName as String): kern,
    ]))
}

func lineWidth(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

/// Big condensed capitals centred on `centreY`. Each line slides up into place from behind a mask
/// (a 0.16 s snap, no overshoot); `age` is the time since the text appeared.
func drawBig(_ ctx: CGContext, _ lines: [String], size requested: CGFloat? = nil, centreY: CGFloat = H / 2,
             age: Double, color: CGColor = white) {
    let n = CGFloat(lines.count)
    var size = requested ?? (n > 1 ? 250 : 300)
    let widest = lines.map { lineWidth(makeLine($0, ctFont(condensed, size), color, kern: -size * 0.01)) }.max() ?? 0
    if widest > W * 0.86 { size *= W * 0.86 / widest }
    let font = ctFont(condensed, size)
    let cap = CTFontGetCapHeight(font)
    let lh = size * 0.94
    for (i, text) in lines.enumerated() {
        let l = makeLine(text, font, color, kern: -size * 0.01)
        let mid = centreY + (n - 1) / 2 * lh - CGFloat(i) * lh
        let baseline = mid - cap / 2
        let p = easeOutExpo(clamp((age - Double(i) * 0.05) / 0.16))
        let drop = CGFloat(1 - p) * cap * 1.2
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: baseline - size * 0.1, width: W, height: cap + size * 0.2))
        ctx.textPosition = CGPoint(x: W / 2 - lineWidth(l) / 2, y: baseline - drop)
        CTLineDraw(l, ctx)
        ctx.restoreGState()
    }
}

/// A short line of text on a dark rounded plate, so it reads over the light app.
func drawPlate(_ ctx: CGContext, _ text: String, size: CGFloat, weight: NSFont.Weight, centre: CGPoint? = nil,
               topRight: CGPoint? = nil, alpha: CGFloat) {
    let l = makeLine(text, sysFont(size, weight), white)
    var ascent: CGFloat = 0, descent: CGFloat = 0
    _ = CTLineGetTypographicBounds(l, &ascent, &descent, nil)
    let padX = size * 0.62, h = size * 1.62
    let w = lineWidth(l) + padX * 2
    var rect = CGRect(x: 0, y: 0, width: w, height: h)
    if let centre { rect.origin = CGPoint(x: centre.x - w / 2, y: centre.y - h / 2) }
    if let topRight { rect.origin = CGPoint(x: topRight.x - w, y: topRight.y - h) }
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: h * 0.26, cornerHeight: h * 0.26, transform: nil))
    ctx.setFillColor(CGColor(gray: 0.04, alpha: alpha))
    ctx.fillPath()
    ctx.textPosition = CGPoint(x: rect.minX + padX, y: rect.midY - (ascent - descent) / 2)
    CTLineDraw(l, ctx)
    ctx.restoreGState()
}

/// Tarn's mark (website/assets/mark.svg): two peaks over a lake, drawn in white.
func drawMark(_ ctx: CGContext, centre: CGPoint, size: CGFloat, alpha: CGFloat) {
    let s = size / 32
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: centre.x, y: centre.y)
    ctx.scaleBy(x: s, y: -s)
    ctx.translateBy(x: -16, y: -17)
    let peaks = CGMutablePath()
    peaks.move(to: CGPoint(x: 3, y: 19))
    for p in [CGPoint(x: 11, y: 8.5), CGPoint(x: 15.5, y: 14), CGPoint(x: 19.5, y: 9.5), CGPoint(x: 29, y: 19)] { peaks.addLine(to: p) }
    ctx.addPath(peaks)
    ctx.setLineWidth(2.3); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(white); ctx.strokePath()
    let lake = CGMutablePath()
    lake.move(to: CGPoint(x: 6, y: 23.5))
    lake.addCurve(to: CGPoint(x: 26, y: 23.5), control1: CGPoint(x: 10, y: 21.2), control2: CGPoint(x: 22, y: 21.2))
    lake.addCurve(to: CGPoint(x: 6, y: 23.5), control1: CGPoint(x: 22, y: 27), control2: CGPoint(x: 10, y: 27))
    lake.closeSubpath()
    ctx.addPath(lake); ctx.setFillColor(white); ctx.fillPath()
    ctx.restoreGState()
}

// MARK: Footage

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
    let s = ClipSource(base.appendingPathComponent(src))
    sources[src] = s
    return s
}

/// Fills the frame with the part of the window the camera looks at.
func drawFootage(_ ctx: CGContext, _ img: CGImage, x: Double, y: Double, z: Double) {
    let iw = CGFloat(img.width), ih = CGFloat(img.height)
    let cw = iw / CGFloat(max(1, z)), ch = cw * H / W
    let cx = min(max(CGFloat(x) * iw, cw / 2), iw - cw / 2)
    let cy = min(max(CGFloat(y) * ih, ch / 2), ih - ch / 2)
    let s = W / cw
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: -(cx - cw / 2) * s, y: H - (ih - (cy - ch / 2)) * s, width: iw * s, height: ih * s))
}

// MARK: Segments

let segs = tl.segments
let starts = segs.indices.map { i in segs[..<i].reduce(0) { $0 + $1.dur } }
let total = segs.reduce(0) { $0 + $1.dur }

func render(_ ctx: CGContext, at t: Double) {
    ctx.setFillColor(black)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    guard let i = starts.lastIndex(where: { $0 <= t + 1e-9 }) else { return }
    let seg = segs[i]
    let local = t - starts[i]
    let push = 1 + (seg.drift ?? 0) * local / seg.dur
    switch seg.type {
    case "big":
        ctx.saveGState()
        ctx.translateBy(x: W / 2, y: H / 2); ctx.scaleBy(x: push, y: push); ctx.translateBy(x: -W / 2, y: -H / 2)
        drawBig(ctx, seg.lines ?? [], age: seg.instant == true ? 1 : local)
        ctx.restoreGState()
    case "clip":
        guard let src = seg.src, let map = seg.map, let cam = seg.cam else { break }
        if let img = source(src).frame(at: sourceTime(map, local)) {
            let c = camera(cam, local)
            drawFootage(ctx, img, x: c.x, y: c.y, z: c.z * push)
        }
        if seg.note == true { drawPlate(ctx, "sped up", size: 21, weight: .medium, topRight: CGPoint(x: W - 40, y: H - 40), alpha: 0.55) }
        if let caption = seg.caption, local < (seg.captionUntil ?? .infinity) {
            drawPlate(ctx, caption, size: 46, weight: .semibold, centre: CGPoint(x: W / 2, y: 112), alpha: 0.86)
        }
    case "end":
        let p = easeOutExpo(clamp(local / 0.4))
        drawMark(ctx, centre: CGPoint(x: W / 2, y: H / 2 + 175), size: 150 * CGFloat(0.94 + 0.06 * p), alpha: CGFloat(p))
        drawBig(ctx, ["TARN"], size: 190, centreY: H / 2 - 20, age: local - 0.06)
        if let tagline = seg.lines?.first {
            let k = CGFloat(easeOutExpo(clamp((local - 0.18) / 0.4)))
            let l = makeLine(tagline, sysFont(44, .regular), CGColor(gray: 1, alpha: 0.72 * k))
            ctx.textPosition = CGPoint(x: W / 2 - lineWidth(l) / 2, y: H / 2 - 190 - (1 - k) * 12)
            CTLineDraw(l, ctx)
        }
    default:
        break  // black
    }
    // The picture goes to black with the music's last note.
    if t > total - 0.4 {
        ctx.setFillColor(CGColor(gray: 0, alpha: clamp((t - (total - 0.4)) / 0.4)))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    }
}

// MARK: Output

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
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: tl.width, kCVPixelBufferHeightKey as String: tl.height,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let frames = Int((total * fps).rounded())
for f in 0..<frames {
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
    if f % 300 == 0 { print("frame \(f)/\(frames)") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print("wrote \(outURL.path) (\(String(format: "%.2f", total)) s)")
