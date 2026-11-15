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
    /// Keyed by the task object: two sessions (or a reused identifier) can never cross jobs.
    private var jobs = [ObjectIdentifier: Job]()
    /// Created once in init. (A lazy var raced on the first concurrent downloads, made two sessions with
    /// overlapping task identifiers, and delivered one download's file to another's caller.)
    private var session: URLSession!

    override init() {
        super.init()
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.timeoutIntervalForRequest = 30            // no bytes for 30 s → fail (then retried)
        c.timeoutIntervalForResource = 60 * 60 * 24
        c.httpMaximumConnectionsPerHost = 12
        if let mocks = ICloudSession.testProtocolClasses { c.protocolClasses = mocks }
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }

    #if os(iOS)
    /// iOS: large downloads also go through a background URLSession, so they keep going while the app is in
    /// the background. That session never carries iCloud cookies (the system follows redirects for it, so we
    /// couldn't keep cookies away from other hosts); a 401/403 there falls back to the normal session.
    private var background: URLSession?
    private var backgroundMinimum: Int64 = .max
    private var backgroundEventsDone: (() -> Void)?

    /// Call once at launch (this also re-attaches to downloads the system finished while the app was suspended).
    public func enableBackgroundDownloads(identifier: String, minimumSize: Int64 = 4 << 20) {
        lock.withLock {
            guard background == nil else { return }
            let c = URLSessionConfiguration.background(withIdentifier: identifier)
            c.sessionSendsLaunchEvents = true
            c.isDiscretionary = false
            c.httpCookieStorage = nil
            c.httpShouldSetCookies = false
            c.urlCache = nil
            c.timeoutIntervalForRequest = 60
            c.timeoutIntervalForResource = 60 * 60 * 24
            c.httpMaximumConnectionsPerHost = 6
            background = URLSession(configuration: c, delegate: self, delegateQueue: nil)
            backgroundMinimum = minimumSize
        }
    }

    /// Hand over the handler from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public func setBackgroundEventsCompletion(_ done: @escaping () -> Void) { lock.withLock { backgroundEventsDone = done } }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = lock.withLock { () -> (() -> Void)? in let d = backgroundEventsDone; backgroundEventsDone = nil; return d }
        if let done { DispatchQueue.main.async { done() } }
    }
    #endif

    /// Downloads one URL (no redirect following) into a temp file and returns it with the response.
    func fetch(_ request: URLRequest, expected: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, HTTPURLResponse) {
        #if os(iOS)
        if let bg = lock.withLock({ expected >= backgroundMinimum ? background : nil }) {
            var plain = request
            plain.setValue(nil, forHTTPHeaderField: "Cookie")
            let (file, h) = try await run(bg.downloadTask(with: plain), expected: expected, progress: progress)
            guard h.statusCode == 401 || h.statusCode == 403, request.value(forHTTPHeaderField: "Cookie") != nil else { return (file, h) }
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        #endif
        return try await run(session.downloadTask(with: request), expected: expected, progress: progress)
    }

    private func run(_ task: URLSessionDownloadTask, expected: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, HTTPURLResponse) {
        let job = Job(progress: progress, expected: expected)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(URL, HTTPURLResponse), Error>) in
                job.continuation = cont
                lock.withLock { jobs[ObjectIdentifier(task)] = job }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func job(_ task: URLSessionTask) -> Job? { lock.withLock { jobs[ObjectIdentifier(task)] } }

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
        guard let j = lock.withLock({ jobs.removeValue(forKey: ObjectIdentifier(task)) }), let cont = j.continuation else { return }
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
