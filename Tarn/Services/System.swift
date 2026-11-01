import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Sparkle
import UserNotifications

/// Watches macOS memory pressure (the signal behind Activity Monitor's Memory Pressure graph)
/// with a dispatch source. Needs no special permission.
final class MemoryWatcher {
    private var source: DispatchSourceMemoryPressure?
    var onPressure: ((_ critical: Bool) -> Void)?

    func start() {
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self, let src = self.source else { return }
            self.onPressure?(src.data.contains(.critical))
        }
        s.resume()
        source = s
    }

    /// Current level: 1 normal, 2 warning, 4 critical.
    static func level() -> Int {
        Int(HardwareInfo.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1)
    }

    static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: "tarn-memory", content: content, trigger: nil))
        }
    }
}

/// App updates through Sparkle. The feed URL and public signing key go into Info.plist only in
/// release builds (docs/DISTRIBUTION.md); builds without them, like local test builds, don't check.
@MainActor
final class Updater: NSObject, ObservableObject {
    private var controller: SPUStandardUpdaterController?
    @Published var canCheck = false
    @Published var lastChecked: Date?

    var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        return (info?["SUFeedURL"] as? String)?.isEmpty == false && (info?["SUPublicEDKey"] as? String)?.isEmpty == false
    }

    func start(autoUpdate: Bool) {
        guard isConfigured, controller == nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        c.updater.automaticallyChecksForUpdates = true
        setAuto(autoUpdate)
        canCheck = c.updater.canCheckForUpdates
        lastChecked = c.updater.lastUpdateCheckDate
        // Check on every launch, quietly.
        c.updater.checkForUpdatesInBackground()
    }

    /// On: updates download in the background and install when Tarn quits.
    /// Off: Tarn still checks and asks before downloading.
    func setAuto(_ on: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = on
    }

    func checkNow() {
        controller?.checkForUpdates(nil)
        lastChecked = Date()
    }
}

enum Attachments {
    static let maxFile: Int64 = 25 << 20
    static let maxChars = 400_000
    /// Longest side of a stored image. About 1,300 image tokens for the Qwen vision encoders.
    static let maxImageSide = 1024

    static func validFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count < 120 && !name.contains("/") && !name.hasPrefix(".") && name.hasSuffix(".jpg")
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) ?? false
    }

    /// Turns a file the user attached into something the model can read.
    static func read(_ url: URL) throws -> Attachment {
        let name = url.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        if size > maxFile { throw ToolFailure("\(name) is larger than 25 MB.") }
        let data = try Data(contentsOf: url)
        if isImage(url) { return try image(data, name: name) }
        var text: String
        var kind = Attachment.Kind.text
        if url.pathExtension.lowercased() == "pdf" || data.starts(with: Data("%PDF-".utf8)) {
            kind = .pdf
            guard let doc = PDFDocument(data: data) else { throw ToolFailure("Tarn couldn’t read \(name). It may be damaged.") }
            if doc.isLocked { throw ToolFailure("\(name) is password-protected.") }
            text = (0..<doc.pageCount).compactMap { i in doc.page(at: i)?.string.map { "[Page \(i + 1)]\n\($0)" } }.joined(separator: "\n\n")
            if text.replacing(/\[Page \d+\]/, with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ToolFailure("\(name) has no selectable text (it may be a scan), so Tarn can’t read it yet.")
            }
        } else {
            if FolderAccess.looksBinary(data) { throw ToolFailure("Tarn can read text files, PDFs and images. \(name) is none of those.") }
            text = String(decoding: data, as: UTF8.self)
        }
        let truncated = text.count > maxChars
        if truncated { text = String(text.prefix(maxChars)) }
        return Attachment(id: newId(), name: name, kind: kind, size: size, text: text, truncated: truncated)
    }

    /// Downscales an image to at most 1024 px and stores it as JPEG in the attachments folder.
    static func image(_ data: Data, name: String) throws -> Attachment {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxImageSide,
              ] as CFDictionary) else {
            throw ToolFailure("Tarn couldn’t open \(name) as an image.")
        }
        let id = newId()
        let file = "\(id).jpg"
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw ToolFailure("Tarn couldn’t save \(name).") }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolFailure("Tarn couldn’t save \(name).") }
        try (out as Data).write(to: Paths.attachments.appendingPathComponent(file), options: .atomic)
        return Attachment(id: id, name: name, kind: .image, size: Int64(out.length), text: "", file: file)
    }

    /// Images or files on the clipboard (for ⌘V in the message box).
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> [Attachment] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.prefix(10).compactMap { try? read($0) }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")] {
            if let d = pb.data(forType: type), let a = try? image(d, name: "Pasted image") { return [a] }
        }
        return []
    }

    static func imageURL(_ a: Attachment) -> URL? {
        guard a.kind == .image, let f = a.file, validFileName(f) else { return nil }
        return Paths.attachments.appendingPathComponent(f)
    }

    static func dataURL(_ a: Attachment) -> String? {
        guard let url = imageURL(a), let d = try? Data(contentsOf: url) else { return nil }
        return "data:image/jpeg;base64," + d.base64EncodedString()
    }
}
