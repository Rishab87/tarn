// Renders Tarn's launch video from a beat-based timeline (video/timeline.json).
// White canvas, typed and "slam" text, app footage with camera zooms, beat pulses and
// zoom-through transitions. Output has no audio; video/build.sh adds the soundtrack.
//
//   swiftc -O -o video/render video/render.swift && video/render video/timeline.json video/out/raw.mp4
import AppKit
import AVFoundation
import CoreText

struct Cam: Decodable { var t: Double; var x: Double; var y: Double; var z: Double }

struct Segment: Decodable {
    var type: String            // text | slams | logo | clip | still | end
    var beats: Double
    var lines: [String]?        // text
    var words: [String]?        // slams
    var src: String?            // clip / still
    var from: Double?           // clip start (seconds into source)
    var speed: Double?          // clip playback speed
    var cam: [Cam]?
    var caption: String?
    var cut: Bool?              // hard cut into this segment (no transition)
}

struct Timeline: Decodable {
    var fps: Int
    var width: Int
    var height: Int
    var bpm: Double
    var segments: [Segment]
}

let args = CommandLine.arguments
let base = URL(fileURLWithPath: args[1]).deletingLastPathComponent()
let tl = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let outURL = URL(fileURLWithPath: args[2])
let W = CGFloat(tl.width), H = CGFloat(tl.height)
let fps = Double(tl.fps)
let beat = 60.0 / tl.bpm

// MARK: Easing and helpers

func clamp(_ v: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, v)) }
func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
func easeOutBack(_ t: Double) -> Double { let c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

func camAt(_ cams: [Cam]?, _ t: Double) -> Cam {
    guard let cams, !cams.isEmpty else { return Cam(t: 0, x: 0.5, y: 0.5, z: 1) }
    if t <= cams[0].t { return cams[0] }
    for i in 1..<cams.count where t <= cams[i].t {
        let a = cams[i - 1], b = cams[i]
        let k = easeInOut(clamp((t - a.t) / max(0.0001, b.t - a.t)))
        return Cam(t: t, x: lerp(a.x, b.x, k), y: lerp(a.y, b.y, k), z: lerp(a.z, b.z, k))
    }
    return cams[cams.count - 1]
}

let ink = CGColor(red: 0.086, green: 0.086, blue: 0.086, alpha: 1)
let muted = CGColor(red: 0.39, green: 0.41, blue: 0.40, alpha: 1)
let serif = "Iowan Old Style"

func font(_ name: String, _ size: CGFloat, bold: Bool = false) -> CTFont {
    if name == "system" { return NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular) as CTFont }
    return CTFontCreateWithName(name as CFString, size, nil)
}

/// Draws one line of text centered on `center`, with alpha and scale.
func drawText(_ ctx: CGContext, _ text: String, _ f: CTFont, _ color: CGColor, center: CGPoint, alpha: Double = 1, scale: Double = 1, kern: CGFloat = -0.5) {
    guard !text.isEmpty, alpha > 0.001 else { return }
    let attr = NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: color, .kern: kern])
    let line = CTLineCreateWithAttributedString(attr)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let typo = CTLineGetBoundsWithOptions(line, [])
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: center.x, y: center.y)
    ctx.scaleBy(x: scale, y: scale)
    ctx.textPosition = CGPoint(x: -typo.width / 2, y: -(bounds.midY))
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func textWidth(_ text: String, _ f: CTFont) -> CGFloat {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: f, .kern: -0.5]))
    return CTLineGetBoundsWithOptions(line, []).width
}

// MARK: Sources

final class ClipSource {
    let gen: AVAssetImageGenerator
    init(_ url: URL) {
        let asset = AVURLAsset(url: url)
        gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 120)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)
        gen.maximumSize = CGSize(width: 2560, height: 1600)
        gen.appliesPreferredTrackTransform = true
    }
    func frame(at seconds: Double) -> CGImage? {
        try? gen.copyCGImage(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600), actualTime: nil)
    }
}

var clips: [String: ClipSource] = [:]
var stills: [String: CGImage] = [:]
func clip(_ src: String) -> ClipSource {
    if let c = clips[src] { return c }
    let c = ClipSource(base.appendingPathComponent(src)); clips[src] = c; return c
}
func still(_ src: String) -> CGImage? {
    if let s = stills[src] { return s }
    guard let img = NSImage(contentsOf: base.appendingPathComponent(src)), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    stills[src] = cg; return cg
}
let icon = NSImage(contentsOf: base.appendingPathComponent("../website/assets/icon-512.png"))?.cgImage(forProposedRect: nil, context: nil, hints: nil)

// MARK: Segment drawing

/// Draws app footage in a rounded "window" panel with a soft shadow, framed by the camera.
func drawPanel(_ ctx: CGContext, _ img: CGImage, cam: Cam, pulse: Double, caption: String?, local: Double) {
    let hasCaption = caption != nil
    let maxW: CGFloat = hasCaption ? 1560 : 1640, maxH: CGFloat = hasCaption ? 860 : 960
    let aspect = CGFloat(img.width) / CGFloat(img.height)
    var pw = maxW, ph = maxW / aspect
    if ph > maxH { ph = maxH; pw = ph * aspect }
    let s = CGFloat(pulse)
    pw *= s; ph *= s
    let cy = hasCaption ? H / 2 + 70 : H / 2
    let rect = CGRect(x: W / 2 - pw / 2, y: cy - ph / 2, width: pw, height: ph)
    let path = CGPath(roundedRect: rect, cornerWidth: 22, cornerHeight: 22, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 60, color: CGColor(gray: 0, alpha: 0.22))
    ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let z = CGFloat(cam.z)
    let drawW = rect.width * z, drawH = rect.height * z
    // camera center in image-normalized coords (y from top) -> keep that point at panel center
    let ox = rect.midX - CGFloat(cam.x) * drawW
    let oy = rect.midY - (1 - CGFloat(cam.y)) * drawH
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: ox, y: oy, width: drawW, height: drawH))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08)); ctx.setLineWidth(1.5); ctx.strokePath()
    ctx.restoreGState()
    if let caption {
        let n = Int(Double(caption.count) * clamp(local / 0.35))
        let shown = String(caption.prefix(n))
        drawText(ctx, shown, font(serif, 58), ink, center: CGPoint(x: W / 2, y: 92))
    }
}

func drawSegment(_ ctx: CGContext, _ seg: Segment, local: Double, segSeconds: Double, absTime: Double) {
    // local: 0…1 progress through the segment
    let sinceBeat = absTime.truncatingRemainder(dividingBy: beat)
    let pulse = 1 + 0.012 * exp(-sinceBeat / 0.09)
    switch seg.type {
    case "text":
        let lines = seg.lines ?? []
        let total = lines.reduce(0) { $0 + $1.count }
        let typed = Int(Double(total) * clamp(local / 0.6))
        let f = font(serif, lines.count > 1 ? 120 : 132)
        var remaining = typed
        let lh: CGFloat = 138
        let top = H / 2 + CGFloat(lines.count - 1) * lh / 2
        let zoom = 1 + 0.05 * local
        for (i, l) in lines.enumerated() {
            let shown = String(l.prefix(max(0, remaining)))
            remaining -= l.count
            let y = top - CGFloat(i) * lh
            drawText(ctx, shown, f, ink, center: CGPoint(x: W / 2, y: y), scale: zoom)
            // caret at the typing position
            if remaining < 0 || (i == lines.count - 1 && remaining == 0 && local < 0.9) {
                if remaining < 0 || Int(absTime * 3.2) % 2 == 0 {
                    let w = textWidth(shown, f) * CGFloat(zoom)
                    ctx.setFillColor(CGColor(red: 0.18, green: 0.49, blue: 0.54, alpha: 1))
                    ctx.fill(CGRect(x: W / 2 + w / 2 + 8, y: y - 52, width: 7, height: 104))
                }
                remaining = Int.min / 2
            }
        }
    case "slams":
        let words = seg.words ?? []
        guard !words.isEmpty else { return }
        let per = 1.0 / Double(words.count)
        let i = min(words.count - 1, Int(local / per))
        let k = clamp((local - Double(i) * per) / (per * 0.35))
        let scale = lerp(1.35, 1.0, easeOutBack(k))
        drawText(ctx, words[i], font(serif, 150), ink, center: CGPoint(x: W / 2, y: H / 2), alpha: clamp(k * 3), scale: scale)
    case "logo", "end":
        let k = clamp(local / 0.3)
        let s = easeOutBack(k)
        if let icon {
            let size = 300 * CGFloat(s)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 50, color: CGColor(gray: 0, alpha: 0.18))
            ctx.draw(icon, in: CGRect(x: W / 2 - size / 2, y: H / 2 + 40 - size / 2 + 40, width: size, height: size))
            ctx.restoreGState()
        }
        let t2 = clamp((local - 0.18) / 0.3)
        drawText(ctx, "Tarn", font("system", 92, bold: true), ink, center: CGPoint(x: W / 2, y: H / 2 - 190), alpha: t2, scale: lerp(0.94, 1, easeInOut(t2)))
        if seg.type == "end" {
            let t3 = clamp((local - 0.35) / 0.3)
            drawText(ctx, "Free, private AI for your Mac.", font(serif, 50), muted, center: CGPoint(x: W / 2, y: H / 2 - 285), alpha: t3)
        }
    case "clip":
        guard let src = seg.src else { return }
        let t = (seg.from ?? 0) + local * segSeconds * (seg.speed ?? 1)
        if let img = clip(src).frame(at: t) {
            drawPanel(ctx, img, cam: camAt(seg.cam, local), pulse: pulse, caption: seg.caption, local: local)
        }
    case "still":
        guard let src = seg.src, let img = still(src) else { return }
        drawPanel(ctx, img, cam: camAt(seg.cam, local), pulse: pulse, caption: seg.caption, local: local)
    default:
        break
    }
}

// MARK: Render loop

let segDur = tl.segments.map { $0.beats * beat }
let starts = segDur.indices.map { i in segDur[..<i].reduce(0, +) }
let total = segDur.reduce(0, +)
let frames = Int(total * fps)
let transition = 0.18 // seconds

try? FileManager.default.removeItem(at: outURL)
try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: tl.width, AVVideoHeightKey: tl.height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 18_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: tl.width, kCVPixelBufferHeightKey as String: tl.height,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

func render(_ ctx: CGContext, at t: Double) {
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    guard let i = starts.lastIndex(where: { $0 <= t }) else { return }
    let seg = tl.segments[i]
    let local = (t - starts[i]) / segDur[i]
    let intoNext = starts[i] + segDur[i] - t
    let next = i + 1 < tl.segments.count ? tl.segments[i + 1] : nil
    if let next, intoNext < transition, next.cut != true {
        // Zoom-through: the outgoing segment grows and fades as the next one settles in.
        let k = easeInOut(1 - intoNext / transition)
        ctx.saveGState()
        ctx.translateBy(x: W / 2, y: H / 2); ctx.scaleBy(x: 1 + 0.12 * k, y: 1 + 0.12 * k); ctx.translateBy(x: -W / 2, y: -H / 2)
        ctx.setAlpha(1 - k)
        drawSegment(ctx, seg, local: local, segSeconds: segDur[i], absTime: t)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.translateBy(x: W / 2, y: H / 2); ctx.scaleBy(x: 0.94 + 0.06 * k, y: 0.94 + 0.06 * k); ctx.translateBy(x: -W / 2, y: -H / 2)
        ctx.setAlpha(k)
        drawSegment(ctx, next, local: 0, segSeconds: segDur[i + 1], absTime: t)
        ctx.restoreGState()
    } else {
        drawSegment(ctx, seg, local: local, segSeconds: segDur[i], absTime: t)
    }
    // Fade to white over the last half second.
    if t > total - 0.5 {
        ctx.setFillColor(CGColor(gray: 1, alpha: clamp((t - (total - 0.5)) / 0.5)))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    }
}

for f in 0..<frames {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    guard let buffer = pb else { fatalError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: tl.width, height: tl.height, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    render(ctx, at: Double(f) / fps)
    CVPixelBufferUnlockBaseAddress(buffer, [])
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(tl.fps)))
    if f % 120 == 0 { print("frame \(f)/\(frames)") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print("wrote \(outURL.path) (\(String(format: "%.1f", total)) s)")
