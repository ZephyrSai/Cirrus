import CirrusCore
import SwiftUI

/// iCloud Drive's Recently Deleted. Items can be put back; Cirrus never deletes anything permanently.
struct DriveTrashView: View {
    let account: Account
    @Environment(AppState.self) private var state
    @State private var nodes: [DriveNode] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var selected = Set<String>()
    @State private var alert: AlertInfo?
    @State private var working = false

    var body: some View {
        Group {
            if !loaded {
                ProgressView("Loading…")
            } else if nodes.isEmpty {
                ContentUnavailableView(account.isICloud ? "No Recently Deleted Items" : "\(account.deletedTitle) Is Empty", systemImage: "trash",
                                       description: Text(error ?? (account.isICloud ? "Items you move to Recently Deleted stay here for 30 days." : "Items you delete in Cirrus wait here until you put them back.")))
            } else {
                List(selection: $selected) {
                    Section {
                        ForEach(nodes, id: \.id) { n in
                            HStack(spacing: 12) {
                                DriveThumb(account: account, node: n, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(n.name)
                                    Text(n.isFolder ? "Folder" : n.size.byteString).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tag(n.id)
                            .swipeActions {
                                Button { Task { await restore([n]) } } label: { Label("Put Back", systemImage: "arrow.uturn.backward") }
                                    .tint(.blue).disabled(state.readOnly)
                            }
                        }
                    } footer: {
                        Text(account.isICloud ? "Put Back returns items to where they were. To erase them for good, use iCloud.com or the Files app; Cirrus never deletes permanently."
                                              : "Put Back returns items to where they were. To erase them for good, use \(account.provider?.displayName ?? "the service")’s own app or website; Cirrus never deletes permanently.")
                    }
                }
                .environment(\.editMode, .constant(.active))
            }
        }
        .navigationTitle(account.deletedTitle)
        .toolbar {
            if !nodes.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button("Put Back \(selected.isEmpty ? "" : "\(selected.count) ")Selected") {
                        Task { await restore(nodes.filter { selected.contains($0.id) }) }
                    }
                    .disabled(selected.isEmpty || state.readOnly || working)
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
    }

    func load() async {
        guard let drive = account.drive else { error = ICloudError.needsSignIn.localizedDescription; loaded = true; return }
        do {
            nodes = try await drive.listTrash().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            error = nil
        } catch { self.error = error.localizedDescription }
        loaded = true
    }

    func restore(_ list: [DriveNode]) async {
        guard let drive = account.drive, !list.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            try await drive.restore(list)
            selected.removeAll()
            DriveFolderModel.memory.removeAll()
            await load()
            state.show(list.count == 1 ? "Put back “\(list[0].name)”" : "Put back \(list.count) items")
        } catch {
            alert = AlertInfo(title: "Couldn’t Put Back", message: error.localizedDescription)
        }
    }
}
