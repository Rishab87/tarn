import CryptoKit
import Foundation

struct DownloadError: LocalizedError {
    enum Kind { case network, checksum, http, cancelled, disk }
    let kind: Kind
    let message: String
    var errorDescription: String? { message }
}

/// Downloads a large file to `<dest>.part`, resuming with HTTP Range requests after pauses,
/// app restarts or dropped connections. The finished file must match the expected size and
/// SHA-256 or it is deleted.
final class Downloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Progress {
        var received: Int64
        var total: Int64
        var bytesPerSec: Double
    }

    private let url: URL
    private let dest: URL
    private let expectedSize: Int64
    private let expectedSHA256: String
    private let onProgress: @Sendable (Progress) -> Void
    private let onVerifying: @Sendable () -> Void

    private var session: URLSession!
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var speed: Double = 0
    private var windowStart = Date()
    private var windowBytes: Int64 = 0
    private var lastEmit = Date.distantPast
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private let lock = NSLock()

    var partURL: URL { dest.appendingPathExtension("part") }

    init(url: URL, dest: URL, expectedSize: Int64, expectedSHA256: String,
         onProgress: @escaping @Sendable (Progress) -> Void, onVerifying: @escaping @Sendable () -> Void) {
        self.url = url
        self.dest = dest
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256.lowercased()
        self.onProgress = onProgress
        self.onVerifying = onVerifying
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        session.invalidateAndCancel()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func run(maxRetries: Int = 8) async throws {
        // A complete file may already be here (app data reset, restored backup): verify and keep it.
        if let existing = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64, existing == expectedSize {
            onVerifying()
            let digest = try await Task.detached(priority: .utility) { [dest] in try Self.sha256(of: dest) }.value
            if digest == expectedSHA256 {
                session.finishTasksAndInvalidate()
                return
            }
            try? FileManager.default.removeItem(at: dest)
        }
        var attempt = 0
        while true {
            if isCancelled { throw DownloadError(kind: .cancelled, message: "Download paused") }
            let before = partSize()
            do {
                if before > expectedSize { try? FileManager.default.removeItem(at: partURL) }
                if partSize() < expectedSize { try await fetchOnce() }
                guard partSize() == expectedSize else {
                    throw DownloadError(kind: .network, message: "The connection closed before the download finished.")
                }
                onVerifying()
                let digest = try await Task.detached(priority: .utility) { [partURL] in try Self.sha256(of: partURL) }.value
                guard digest == expectedSHA256 else {
                    try? FileManager.default.removeItem(at: partURL)
                    throw DownloadError(kind: .checksum, message: "The downloaded file was damaged. Tarn deleted it; try again.")
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: partURL, to: dest)
                session.finishTasksAndInvalidate()
                return
            } catch let e as DownloadError where e.kind == .network && !isCancelled {
                if partSize() > before { attempt = 0 }
                guard attempt < maxRetries else { throw e }
                attempt += 1
                try await Task.sleep(for: .seconds(min(30, pow(2, Double(attempt)))))
            } catch {
                if isCancelled { throw DownloadError(kind: .cancelled, message: "Download paused") }
                if let e = error as? DownloadError { throw e }
                if (error as NSError).code == NSFileWriteOutOfSpaceError || (error as NSError).code == Int(ENOSPC) {
                    throw DownloadError(kind: .disk, message: "Your Mac ran out of storage space.")
                }
                throw DownloadError(kind: .network, message: "Tarn lost its internet connection. Check your connection and try again.")
            }
        }
    }

    private func partSize() -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? Int64) ?? 0
    }

    private func fetchOnce() async throws {
        let have = partSize()
        if !FileManager.default.fileExists(atPath: partURL.path) {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
        }
        var req = URLRequest(url: url)
        if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        received = have
        windowStart = Date()
        windowBytes = 0
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            continuation = c
            lock.unlock()
            session.dataTask(with: req).resume()
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        try? handle?.close()
        handle = nil
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            if status == 206 || status == 200 {
                let fh = try FileHandle(forWritingTo: partURL)
                if status == 200 {
                    // Server ignored the range: start over.
                    try fh.truncate(atOffset: 0)
                    received = 0
                } else {
                    try fh.seekToEnd()
                }
                handle = fh
                completionHandler(.allow)
            } else if status == 416 {
                try? FileManager.default.removeItem(at: partURL)
                completionHandler(.cancel)
                finish(DownloadError(kind: .network, message: "The download restarted."))
            } else {
                completionHandler(.cancel)
                let kind: DownloadError.Kind = status >= 500 || status == 429 ? .network : .http
                finish(DownloadError(kind: kind, message: "The download server answered \(status). Try again later."))
            }
        } catch {
            completionHandler(.cancel)
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            finish(DownloadError(kind: .disk, message: "Your Mac ran out of storage space."))
            return
        }
        received += Int64(data.count)
        windowBytes += Int64(data.count)
        let now = Date()
        let dt = now.timeIntervalSince(windowStart)
        if dt >= 1 {
            let inst = Double(windowBytes) / dt
            speed = speed == 0 ? inst : speed * 0.7 + inst * 0.3
            windowStart = now
            windowBytes = 0
        }
        if received > expectedSize {
            dataTask.cancel()
            try? FileManager.default.removeItem(at: partURL)
            finish(DownloadError(kind: .checksum, message: "The download is larger than expected, so Tarn stopped it."))
            return
        }
        if now.timeIntervalSince(lastEmit) > 0.25 {
            lastEmit = now
            onProgress(Progress(received: received, total: expectedSize, bytesPerSec: speed))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onProgress(Progress(received: received, total: expectedSize, bytesPerSec: speed))
        if let error {
            finish(isCancelled ? DownloadError(kind: .cancelled, message: "Download paused")
                : DownloadError(kind: .network, message: error.localizedDescription))
        } else {
            finish(nil)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
