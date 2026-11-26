import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One frozen picture of a display, taken the moment the chord fires. The overlay draws on top
/// of it, so the region the user circles is exactly what the model sees.
struct ScreenFrame {
    let image: CGImage
    /// The display in global AppKit coordinates (points, bottom-left origin).
    let screenFrame: CGRect
    /// The display minus the menu bar and Dock.
    let visibleFrame: CGRect

    var pixelsPerPoint: CGFloat { screenFrame.width > 0 ? CGFloat(image.width) / screenFrame.width : 1 }

    /// The selected region as an image attachment (stored like a pasted screenshot).
    func crop(_ selection: CGRect, name: String) throws -> Attachment {
        guard let rect = ScreenGeometry.cropRect(selection: selection, viewSize: screenFrame.size,
                                                  imageSize: CGSize(width: image.width, height: image.height)),
              let cropped = image.cropping(to: rect) else { throw ToolFailure("That selection is off the screen.") }
        return try Attachments.image(ScreenCapture.png(cropped), name: name)
    }
}

enum ScreenCapture {
    /// Screen Recording, as macOS reports it right now.
    static var permitted: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows macOS's Screen Recording prompt the first time; later calls do nothing.
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    /// The display under the pointer: where the user is looking, and where the overlay opens.
    @MainActor
    static func screenUnderPointer() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    /// Captures one display at its native pixel size, leaving out Tarn's own floating windows.
    @MainActor
    static func capture(_ screen: NSScreen, excludingWindowNumbers excluded: [Int]) async throws -> ScreenFrame {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw ToolFailure("Tarn couldn’t find that display.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw ToolFailure("Tarn couldn’t find that display.") }
        let skip = content.windows.filter { excluded.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: skip)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return ScreenFrame(image: image, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    static func png(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw ToolFailure("Tarn couldn’t save the capture.") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ToolFailure("Tarn couldn’t save the capture.") }
        return out as Data
    }

    /// Loads an image file as a frozen "screen" (Debug fixtures).
    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
