import SwiftUI

struct FinderDrivesView: View {
    @ObservedObject var manager: FinderDriveManager
    @Environment(\.dismiss) private var dismiss
    @State private var remove: FinderDriveManager.Drive?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Finder Drives").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Open and edit files in Finder. Saved changes upload to R2. You can also create, rename, move, and delete files and folders.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Deletion permanently removes files from R2.").font(.callout).foregroundStyle(.secondary)
            if !manager.isPackaged { Text("Build and open R2 Desk.app to use Finder drives.") }
            else if manager.drives.isEmpty { Text("Right-click a bucket. Select Add to Finder.").foregroundStyle(.secondary) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(manager.drives) { drive in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label(drive.configuration.bucket, systemImage: "externaldrive")
                                    Spacer()
                                    if manager.pending.contains(drive.id) { ProgressView().controlSize(.small) }
                                    Button("Open") { Task { do { try await manager.open(drive) } catch { manager.error = error.localizedDescription } } }
                                    Button("Remove…") { remove = drive }
                                }.disabled(manager.pending.contains(drive.id))
                                Text(drive.name).font(.caption).foregroundStyle(.secondary)
                                if let message = manager.messages[drive.id] { Text(message).font(.callout).foregroundStyle(.orange) }
                            }
                        }
                    }
                }.frame(maxHeight: 280)
            }
            if let error = manager.error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Extension Settings", action: manager.openSettings)
                Button("Refresh") { Task { await manager.refresh() } }.disabled(!manager.isPackaged)
            }
        }.padding(24).frame(width: 570)
            .confirmationDialog("Remove this Finder drive?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    guard let drive = remove else { return }; remove = nil
                    Task { do { try await manager.remove(drive) } catch { manager.error = error.localizedDescription } }
                }
            } message: { Text("Files in R2 stay in the bucket. macOS preserves local files with changes that have not uploaded.") }
    }
}
