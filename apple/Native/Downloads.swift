import Foundation
import CryptoKit
import UIKit

/// Large-file downloads (gateway archives, GGUF models) with progress, resume after a
/// dropped connection, and integrity checks before the file is moved into place.
@MainActor final class Downloads: ObservableObject {
    static let shared = Downloads()
    struct Item: Equatable {
        var received: Int64 = 0
        var total: Int64 = 0
        var verifying = false
        var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
    }
    @Published private(set) var active = [String:Item]()
    @Published private(set) var errors = [String:String]()
    private var jobs = [String:Job]()

    func isActive(_ id: String) -> Bool { active[id] != nil }

    /// Downloads `url` to `destination`. The file only appears there after its size and
    /// SHA-256 (when given) match, so readers never see a partial file.
    func start(_ id: String, url: URL, to destination: URL, size: Int64? = nil, sha256: String? = nil,
               magic: Data? = nil, done: @escaping @MainActor () -> Void = {}) {
        guard jobs[id] == nil else { return }
        errors[id] = nil
        active[id] = Item(total: size ?? 0)
        let job = Job(url: url, destination: destination, size: size, sha256: sha256?.lowercased(), magic: magic)
        jobs[id] = job
        UIApplication.shared.isIdleTimerDisabled = true
        job.progress = { [weak self, weak job] received, total in
            Task { @MainActor in
                guard let self, let job, self.jobs[id] === job else { return }
                self.active[id] = Item(received: received, total: total > 0 ? total : (size ?? 0))
            }
        }
        job.verifying = { [weak self, weak job] in
            Task { @MainActor in if let self, let job, self.jobs[id] === job { self.active[id]?.verifying = true } }
        }
        job.finish = { [weak self, weak job] error in
            Task { @MainActor in
                guard let self, let job, self.jobs[id] === job else { return }
                self.jobs[id] = nil
                self.active[id] = nil
                if let error { self.errors[id] = error } else { done() }
                if self.jobs.isEmpty && !ModelServer.shared.running { UIApplication.shared.isIdleTimerDisabled = false }
            }
        }
        job.begin()
    }

    /// Stops a download and keeps what was received so the next start resumes.
    func pause(_ id: String) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.pause()
        active[id] = nil
        if jobs.isEmpty && !ModelServer.shared.running { UIApplication.shared.isIdleTimerDisabled = false }
    }

    func clearError(_ id: String) { errors[id] = nil }

    nonisolated static func excludeFromBackup(_ folder: URL) { excludeFolderFromBackup(folder) }
}

private final class Job: NSObject, URLSessionDownloadDelegate {
    let url: URL
    let destination: URL
    let size: Int64?
    let sha256: String?
    let magic: Data?
    var progress: (Int64, Int64) -> Void = { _, _ in }
    var verifying: () -> Void = {}
    var finish: (String?) -> Void = { _ in }
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var paused = false
    private var resumeFile: URL { destination.appendingPathExtension("resume") }
    private var partFile: URL { destination.appendingPathExtension("part") }

    init(url: URL, destination: URL, size: Int64?, sha256: String?, magic: Data?) {
        self.url = url; self.destination = destination; self.size = size; self.sha256 = sha256; self.magic = magic
    }

    func begin() {
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 12
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        if let data = try? Data(contentsOf: resumeFile) {
            try? FileManager.default.removeItem(at: resumeFile)
            task = session.downloadTask(withResumeData: data)
        } else {
            var request = URLRequest(url: url)
            request.setValue("Allinone-Local", forHTTPHeaderField: "User-Agent")
            task = session.downloadTask(with: request)
        }
        task?.resume()
    }

    func pause() {
        paused = true
        task?.cancel { [resumeFile] data in try? data?.write(to: resumeFile, options: .atomic) }
        session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this method returns, so move it first.
        let manager = FileManager.default
        try? manager.removeItem(at: partFile)
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            fail("HTTP \(http.statusCode)"); return
        }
        do { try manager.moveItem(at: location, to: partFile) } catch { fail(error.localizedDescription); return }
        verifying()
        do {
            try verify(partFile)
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: partFile, to: destination)
            session.finishTasksAndInvalidate()
            finish(nil)
        } catch {
            try? manager.removeItem(at: partFile)
            fail(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !paused else { return }
        let ns = error as NSError
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeFile, options: .atomic)
        }
        fail(ns.code == NSURLErrorCancelled ? "أُلغي التنزيل" : error.localizedDescription + " — اضغط تنزيل للمتابعة من حيث توقف")
    }

    private func fail(_ message: String) {
        session?.finishTasksAndInvalidate()
        finish(message)
    }

    private func verify(_ file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        if let size, size > 0, Int64(length) != size {
            throw LinkError.message("حجم الملف لا يطابق المتوقع (\(length) بدل \(size))")
        }
        try handle.seek(toOffset: 0)
        if let magic {
            guard try handle.read(upToCount: magic.count) == magic else { throw LinkError.message("الملف المحمّل ليس بالصيغة المتوقعة") }
            try handle.seek(toOffset: 0)
        }
        guard let sha256 else { return }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw LinkError.message("بصمة الملف لا تطابق المتوقع. أُعيد حذفه، حاول التنزيل مجددا") }
    }
}
