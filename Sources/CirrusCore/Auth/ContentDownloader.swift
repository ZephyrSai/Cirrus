import Foundation

/// File downloads from iCloud's content servers through one long-lived session with a real
/// delegate: progress is reported as bytes arrive, connections are reused (fast thumbnails),
/// redirects are followed by us, and cancellation stops the task.
public final class ContentDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let shared = ContentDownloader()

    final class Job {
        let progress: @Sendable (Int64, Int64) -> Void
        let expected: Int64
        var file: URL?
        var moveError: Error?
        var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
        init(progress: @escaping @Sendable (Int64, Int64) -> Void, expected: Int64) { self.progress = progress; self.expected = expected }
    }

    private let lock = NSLock()
    private var jobs = [Int: Job]()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.timeoutIntervalForRequest = 30            // no bytes for 30 s → fail (then retried)
        c.timeoutIntervalForResource = 60 * 60 * 24
        c.httpMaximumConnectionsPerHost = 12
        if let mocks = ICloudSession.testProtocolClasses { c.protocolClasses = mocks }
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// Downloads one URL (no redirect following) into a temp file and returns it with the response.
    func fetch(_ request: URLRequest, expected: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, HTTPURLResponse) {
        let task = session.downloadTask(with: request)
        let job = Job(progress: progress, expected: expected)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(URL, HTTPURLResponse), Error>) in
                job.continuation = cont
                lock.withLock { jobs[task.taskIdentifier] = job }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func job(_ task: URLSessionTask) -> Job? { lock.withLock { jobs[task.taskIdentifier] } }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let j = job(downloadTask) else { return }
        j.progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : j.expected)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let j = job(downloadTask) else { return }
        // The system deletes `location` when this returns, so claim it now.
        let keep = Paths.tempFile(named: "download")
        do { try FileManager.default.moveItem(at: location, to: keep); j.file = keep } catch { j.moveError = error }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let j = lock.withLock({ jobs.removeValue(forKey: task.taskIdentifier) }), let cont = j.continuation else { return }
        if let error {
            if let f = j.file { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
            cont.resume(throwing: (error as? URLError)?.code == .cancelled ? ICloudError.cancelled : error)
        } else if let e = j.moveError {
            cont.resume(throwing: e)
        } else if let f = j.file, let h = task.response as? HTTPURLResponse {
            cont.resume(returning: (f, h))
        } else {
            cont.resume(throwing: ICloudError.http((task.response as? HTTPURLResponse)?.statusCode ?? 0, "Download returned no data"))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? { nil }
}
