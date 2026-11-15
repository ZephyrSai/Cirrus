import CirrusCore
import SwiftUI

/// The transfer queue: every download, upload, export and backup with progress, speed, time left and Retry.
struct TransfersView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let _ = state.transfersVersion
        let all = Array(TransferManager.shared.transfers.reversed())
        let active = all.filter { !$0.isFinished }
        let done = all.filter(\.isFinished)
        List {
            if all.isEmpty {
                ContentUnavailableView("No Transfers", systemImage: "arrow.up.arrow.down.circle",
                                       description: Text("Downloads, uploads, exports and backups show up here."))
                    .listRowBackground(Color.clear)
            }
            if !active.isEmpty {
                Section {
                    ForEach(active) { TransferRow(transfer: $0, version: state.transfersVersion) }
                } header: {
                    let o = TransferManager.shared.overall
                    Text("\(o.count) active · \(o.done.byteString) of \(o.total.byteString)")
                }
            }
            if !done.isEmpty {
                Section("Finished") { ForEach(done) { TransferRow(transfer: $0, version: state.transfersVersion) } }
            }
        }
        .navigationTitle("Transfers")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button { TransferManager.shared.clearFinished() } label: { Label("Clear Completed", systemImage: "checkmark.circle") }
                    Button { TransferManager.shared.clearAllFinished() } label: { Label("Clear All Finished", systemImage: "xmark.circle") }
                    Divider()
                    Button(role: .destructive) { TransferManager.shared.cancelAll() } label: { Label("Stop All", systemImage: "stop.circle") }
                        .disabled(active.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

struct TransferRow: View {
    let transfer: Transfer
    /// Transfer is a class: a changing version makes SwiftUI redraw the row.
    let version: Int

    var body: some View {
        let t = transfer
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(t.title).lineLimit(2)
                if !t.isFinished || t.state == .done {
                    if t.state == .running || t.state == .queued {
                        ProgressView(value: t.fraction).tint(tint)
                    }
                }
                Text(status).font(.caption).foregroundStyle(stateColor).lineLimit(3)
                if !t.detail.isEmpty && t.state != .done { Text(t.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            switch t.state {
            case .queued, .running:
                Button { TransferManager.shared.cancel(t) } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).accessibilityLabel("Stop")
            case .failed, .cancelled:
                // A transfer of an account that was signed out can't be retried.
                if accountGone {
                    Image(systemName: "person.crop.circle.badge.xmark").font(.title3).foregroundStyle(.secondary).accessibilityLabel("Signed out")
                } else {
                    Button { TransferManager.shared.retry(t) } label: { Image(systemName: "arrow.clockwise.circle.fill").font(.title3) }
                        .buttonStyle(.borderless).accessibilityLabel("Retry")
                }
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    var accountGone: Bool {
        guard let g = transfer.group, g.hasPrefix("acct:") else { return false }
        return AccountManager.shared.account(id: String(g.dropFirst(5))) == nil
    }

    var icon: String {
        switch transfer.direction {
        case .download: return "arrow.down.circle"
        case .upload: return "arrow.up.circle"
        case .copy: return "doc.on.doc"
        case .other: return "gearshape.2"
        }
    }

    var tint: Color { transfer.direction == .upload ? .green : .accentColor }

    var stateColor: Color {
        if case .failed = transfer.state { return .red }
        return .secondary
    }

    var status: String {
        let t = transfer
        switch t.state {
        case .queued: return "Waiting…"
        case .running:
            var parts = [t.total > 0 ? "\(t.completed.byteString) of \(t.total.byteString)" : t.completed.byteString]
            if t.speed > 1 { parts.append("\(Int64(t.speed).byteString)/s") }
            if let eta = t.etaText { parts.append(eta) }
            return parts.joined(separator: " · ")
        case .done:
            let took = t.startedAt.flatMap { s in t.finishedAt.map { $0.timeIntervalSince(s) } } ?? 0
            let base = t.total > 0 ? t.total.byteString : "Done"
            return (t.detail.isEmpty ? base : t.detail) + (took > 2 ? " · \(Duration.seconds(took).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))" : "")
        case .failed(let m): return m
        case .cancelled: return "Stopped"
        }
    }
}
