import Foundation

public final class Transfer: Identifiable, @unchecked Sendable {
    public enum State: Equatable, Sendable { case queued, running, done, failed(String), cancelled }
    public enum Direction: Sendable { case download, upload, copy, other }

    public let id = UUID()
    public let title: String
    public let direction: Direction
    public let group: String?
    private let lock = NSLock()
    private var _detail: String
    private var _total: Int64
    private var _completed: Int64 = 0
    private var _state: State = .queued
    private var _speed: Double = 0
    private var lastSample: (Date, Int64)?
    public var resultURL: URL?
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    let work: @Sendable (Transfer) async throws -> Void
    var task: Task<Void, Never>?
    weak var manager: TransferManager?

    init(title: String, detail: String, direction: Direction, total: Int64, group: String?, work: @escaping @Sendable (Transfer) async throws -> Void) {
        self.title = title; _detail = detail; self.direction = direction; _total = total; self.group = group; self.work = work
    }

    public var detail: String { lock.withLock { _detail } }
    public var total: Int64 { lock.withLock { _total } }
    public var completed: Int64 { lock.withLock { _completed } }
    public var state: State { lock.withLock { _state } }
    public var speed: Double { lock.withLock { _speed } }
    public var fraction: Double { let t = total; return t > 0 ? min(1, Double(completed) / Double(t)) : (state == .done ? 1 : 0) }
    public var isFinished: Bool { switch state { case .done, .failed, .cancelled: return true; default: return false } }

    /// Called from any thread.
    public func report(_ done: Int64, _ total: Int64) {
        lock.withLock {
            _completed = done
            if total > 0 { _total = total }
            let now = Date()
            if let (t, b) = lastSample {
                let dt = now.timeIntervalSince(t)
                if dt > 0.4 {
                    let inst = Double(done - b) / dt
                    _speed = _speed == 0 ? inst : _speed * 0.7 + inst * 0.3
                    lastSample = (now, done)
                }
            } else { lastSample = (now, done) }
        }
        manager?.setNeedsNotify()
    }

    public func setDetail(_ s: String) { lock.withLock { _detail = s }; manager?.setNeedsNotify() }
    func setState(_ s: State) {
        lock.withLock {
            _state = s
            if s == .running { startedAt = Date() }
            if s == .done || s == .cancelled { finishedAt = Date() }
            if case .failed = s { finishedAt = Date() }
            if s == .done, _total > 0 { _completed = _total }
        }
    }

    public var etaText: String? {
        let s = speed, remaining = total - completed
        guard s > 1, remaining > 0, state == .running else { return nil }
        let secs = Double(remaining) / s
        let f = DateComponentsFormatter()
        f.allowedUnits = secs > 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: secs).map { "\($0) left" }
    }
}

/// Queue for downloads, uploads, exports and copies with bounded concurrency.
@MainActor
public final class TransferManager {
    public static let shared = TransferManager()
    public static let changed = Notification.Name("CirrusTransfersChanged")
    public private(set) var transfers: [Transfer] = []
    public var maxConcurrent = max(2, UserDefaults.standard.integer(forKey: "maxTransfers") == 0 ? 4 : UserDefaults.standard.integer(forKey: "maxTransfers"))
    nonisolated(unsafe) private var notifyPending = false
    private let notifyLock = NSLock()

    @discardableResult
    public func enqueue(_ title: String, detail: String = "", direction: Transfer.Direction, total: Int64 = 0, group: String? = nil,
                        work: @escaping @Sendable (Transfer) async throws -> Void) -> Transfer {
        let t = Transfer(title: title, detail: detail, direction: direction, total: total, group: group, work: work)
        t.manager = self
        transfers.append(t)
        pump()
        post()
        return t
    }

    public var active: [Transfer] { transfers.filter { !$0.isFinished } }
    public var running: [Transfer] { transfers.filter { $0.state == .running } }

    public var overall: (done: Int64, total: Int64, count: Int) {
        let a = active
        return (a.reduce(0) { $0 + $1.completed }, a.reduce(0) { $0 + max($1.total, $1.completed) }, a.count)
    }

    func pump() {
        var runningCount = running.count
        for t in transfers where t.state == .queued && runningCount < maxConcurrent {
            runningCount += 1
            t.setState(.running)
            t.task = Task.detached(priority: .utility) {
                do {
                    try await t.work(t)
                    t.setState(.done)
                } catch is CancellationError {
                    t.setState(.cancelled)
                } catch ICloudError.cancelled {
                    t.setState(.cancelled)
                } catch {
                    if Task.isCancelled { t.setState(.cancelled) } else { t.setState(.failed(error.localizedDescription)) }
                    Log.error("transfer failed: \(t.title): \(error.localizedDescription)")
                }
                await MainActor.run { TransferManager.shared.pump(); TransferManager.shared.post() }
            }
        }
    }

    public func cancel(_ t: Transfer) {
        if t.state == .queued { t.setState(.cancelled) } else { t.task?.cancel() }
        post()
    }

    public func cancelAll() { for t in active { cancel(t) } }

    public func retry(_ t: Transfer) {
        guard case .failed = t.state else { if t.state != .cancelled { return }; return retryNow(t) }
        retryNow(t)
    }

    private func retryNow(_ t: Transfer) {
        let n = Transfer(title: t.title, detail: t.detail, direction: t.direction, total: t.total, group: t.group, work: t.work)
        n.manager = self
        if let i = transfers.firstIndex(where: { $0.id == t.id }) { transfers[i] = n } else { transfers.append(n) }
        pump(); post()
    }

    public func clearFinished() {
        transfers.removeAll { $0.isFinished && $0.state != .failed("") && !isFailed($0) }
        post()
    }

    public func clearAllFinished() { transfers.removeAll { $0.isFinished }; post() }

    func isFailed(_ t: Transfer) -> Bool { if case .failed = t.state { return true }; return false }

    nonisolated func setNeedsNotify() {
        let schedule: Bool = notifyLock.withLock {
            if notifyPending { return false }
            notifyPending = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.notifyLock.withLock { self.notifyPending = false }
            MainActor.assumeIsolated { self.post() }
        }
    }

    func post() { NotificationCenter.default.post(name: Self.changed, object: self) }

    /// Wait until every transfer in a group has finished (used by sync/backup runs).
    public func waitForGroup(_ group: String) async {
        while transfers.contains(where: { $0.group == group && !$0.isFinished }) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
