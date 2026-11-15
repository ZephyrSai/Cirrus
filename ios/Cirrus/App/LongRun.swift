import BackgroundTasks
import CirrusCore
import UIKit

/// Keeps a user-started long job (Back Up iCloud, Export) running when the app leaves the screen.
///
/// - iOS 26 and later: a `BGContinuedProcessingTask`, which the system shows with a progress indicator and
///   which the user can stop from there (that cancels the job; running it again continues where it stopped).
/// - Earlier: a regular background-task assertion (a short grace period), and the screen is kept awake while
///   Cirrus is in front so auto-lock doesn't suspend the job.
@MainActor
final class LongRun {
    private var assertion: UIBackgroundTaskIdentifier = .invalid
    private var continued: AnyObject?          // BGContinuedProcessingTask
    private var finished = false
    private var last: (done: Int64, total: Int64) = (0, 0)
    private let onExpire: @MainActor () -> Void
    private static var running = 0

    private init(onExpire: @escaping @MainActor () -> Void) { self.onExpire = onExpire }

    static func start(title: String, subtitle: String, onExpire: @escaping @MainActor () -> Void) -> LongRun {
        let run = LongRun(onExpire: onExpire)
        running += 1
        UIApplication.shared.isIdleTimerDisabled = true
        run.assertion = UIApplication.shared.beginBackgroundTask(withName: "Cirrus: \(title)") { [weak run] in
            MainActor.assumeIsolated { run?.endAssertion() }
        }
        if #available(iOS 26.0, *) { run.submitContinued(title: title, subtitle: subtitle) }
        return run
    }

    @available(iOS 26.0, *)
    private func submitContinued(title: String, subtitle: String) {
        let id = (Bundle.main.bundleIdentifier ?? "io.github.zephyrsai.cirrus.ios") + ".run." + UUID().uuidString.prefix(8).lowercased()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { [weak self] task in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                    self.attach(task)
                }
            }
        }
        guard registered else { Log.status("continued processing: identifier not permitted"); return }
        let req = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: subtitle)
        req.strategy = .fail     // if the system can't take it now, the job still runs while Cirrus is open
        do { try BGTaskScheduler.shared.submit(req) } catch { Log.status("continued processing not available: \((error as NSError).code)") }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        if finished { task.setTaskCompleted(success: true); return }
        continued = task
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.expired() } }
        }
        task.progress.totalUnitCount = max(1, last.total)
        task.progress.completedUnitCount = min(last.done, max(1, last.total))
    }

    private func expired() {
        guard !finished else { return }
        Log.status("long run expired by the system")
        onExpire()
    }

    func update(done: Int64, total: Int64, subtitle: String? = nil) {
        last = (done, total)
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = max(1, total)
            task.progress.completedUnitCount = min(done, max(1, total))
            if let subtitle { task.updateTitle(task.title, subtitle: subtitle) }
        }
    }

    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        continued = nil
        endAssertion()
        Self.running -= 1
        if Self.running <= 0 { Self.running = 0; UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func endAssertion() {
        if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion); assertion = .invalid }
    }

    // MARK: Ordinary transfers

    private static var transferAssertion: UIBackgroundTaskIdentifier = .invalid

    /// While anything is queued or transferring, ask for the usual background grace period so switching apps
    /// briefly doesn't stop an upload. (Large downloads also continue in the system's background session.)
    static func keepAliveWhileBusy(_ busy: Bool) {
        if busy, transferAssertion == .invalid {
            transferAssertion = UIApplication.shared.beginBackgroundTask(withName: "Cirrus transfers") {
                MainActor.assumeIsolated {
                    UIApplication.shared.endBackgroundTask(LongRun.transferAssertion)
                    LongRun.transferAssertion = .invalid
                }
            }
        } else if !busy, transferAssertion != .invalid {
            UIApplication.shared.endBackgroundTask(transferAssertion)
            transferAssertion = .invalid
        }
    }
}
