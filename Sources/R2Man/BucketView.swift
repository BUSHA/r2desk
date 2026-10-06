import SwiftUI
import R2Core

struct BucketView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tab: FolderTab
    @State private var sort = [KeyPathComparator(\RemoteBucket.name)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Buckets").font(.callout)
                Spacer()
                if tab.loading { ProgressView().controlSize(.mini).padding(.trailing, 8) }
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search buckets", text: $tab.search).textFieldStyle(.plain)
                        .onChange(of: tab.search) { _, _ in tab.selection.formIntersection(Set(tab.visibleBuckets.map(\.name))) }
                    if !tab.search.isEmpty {
                        Button { tab.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }.font(.callout).padding(7).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6)).frame(width: 210)
            }.padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            ZStack {
                Table(tab.visibleBuckets.sorted(using: sort), selection: $tab.selection, sortOrder: $sort) {
                    TableColumn("Name", value: \.name) { bucket in
                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive.fill").font(.system(size: 19)).foregroundStyle(.orange).frame(width: 24)
                            Text(bucket.name).lineLimit(1).padding(.vertical, 6)
                        }
                    }.width(min: 220, ideal: 380)
                    TableColumn("Created") { bucket in
                        Text(bucket.created?.formatted(date: .abbreviated, time: .shortened) ?? "—").foregroundStyle(.secondary)
                    }.width(min: 140, ideal: 180)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let bucket = tab.visibleBuckets.first(where: { ids.contains($0.name) }), ids.count == 1 {
                        Button("Open Bucket") { model.openBucket(bucket, tab: tab) }
                        Button("Open in New Tab") { model.openTab(connectionID: tab.connectionID, location: .folder(bucket: bucket.name, prefix: "")) }
                    }
                } primaryAction: { ids in
                    if let bucket = tab.visibleBuckets.first(where: { ids.contains($0.name) }) { model.openBucket(bucket, tab: tab) }
                }
                .onKeyPress(.return) {
                    guard tab.selection.count == 1, let bucket = tab.visibleBuckets.first(where: { tab.selection.contains($0.name) }) else { return .ignored }
                    model.openBucket(bucket, tab: tab); return .handled
                }
                if tab.loading && tab.buckets.isEmpty {
                    state(icon: "icloud", title: "Load buckets…") { ProgressView().controlSize(.small) }
                } else if let error = tab.error {
                    state(icon: "exclamationmark.icloud", title: "Buckets could not be loaded", detail: error) {
                        Button("Try Again") { model.reload(tab) }
                        Button("Edit Connection") { if let connection = model.connection(tab.connectionID) { model.edit(connection) } }
                    }
                } else if tab.visibleBuckets.isEmpty {
                    state(icon: tab.search.isEmpty ? "externaldrive" : "magnifyingglass", title: tab.search.isEmpty ? "No buckets" : "No matching buckets") {
                        if tab.search.isEmpty { Button("Refresh") { model.reload(tab) } }
                        else { Button("Clear Search") { tab.search = "" } }
                    }
                }
            }
        }
    }

    private func state<Actions: View>(icon: String, title: String, detail: String = "", @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44, weight: .light)).foregroundStyle(.orange)
            Text(title).font(.title3.weight(.semibold))
            if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440) }
            HStack { actions() }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor))
    }
}
