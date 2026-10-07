import SwiftUI
import R2Core
import UniformTypeIdentifiers
import QuickLookUI

private extension RemoteItem {
    var modificationSortDate: Date { modified ?? .distantPast }
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebar.navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            HSplitView {
                browser.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                if model.showTransfers {
                    TransfersView().environmentObject(model)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 420, maxHeight: .infinity)
                }
            }
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
                } label: {
                    Image(systemName: "sidebar.left").frame(width: 24, height: 24)
                }
                .help(sidebarVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
                .accessibilityLabel("Toggle Sidebar")
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
            ToolbarItemGroup(placement: .navigation) {
                if model.current != nil {
                    Button(action: model.goBack) { Image(systemName: "chevron.left") }
                        .disabled(model.current?.canGoBack != true).help("Back")
                    Button(action: model.goForward) { Image(systemName: "chevron.right") }
                        .disabled(model.current?.canGoForward != true).help("Forward")
                    Button(action: model.goUp) { Image(systemName: "arrow.up") }
                        .disabled(model.current?.location.parent == nil).help("Parent folder")
                }
            }
            ToolbarItem(placement: .principal) {
                if let tab = model.current {
                    Text(tab.bucket ?? model.connectionName(tab.connectionID))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                        .help(model.connectionName(tab.connectionID))
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.current != nil {
                    if model.current?.bucket != nil {
                    Button(action: model.chooseUpload) { Label("Upload", systemImage: "arrow.up.doc") }
                        .disabled(model.busy).help("Upload")
                    Button(action: model.downloadSelection) { Label("Download", systemImage: "arrow.down.doc") }
                        .disabled(model.busy || model.current?.selectedItems.isEmpty != false).help("Download")
                    }
                    Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                    Button { model.showTransfers.toggle() } label: { Image(systemName: "list.bullet.rectangle") }.help("Transfers")
                }
            }
        }
        .sheet(isPresented: $model.showConnection) {
            ConnectionView(existing: model.editingConnection).environmentObject(model)
        }
        .sheet(item: $model.previewDocument, onDismiss: model.clearPreview) { document in
            PreviewSheet(document: document)
        }
        .alert("Operation failed", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: { Text(model.alert ?? "") }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            if !model.tabs.isEmpty { tabBar }
            if let tab = model.current {
                if tab.bucket == nil { BucketView(tab: tab).id(tab.id) }
                else { FolderView(tab: tab).id(tab.id) }
                footer
            } else {
                VStack(spacing: 16) {
                    if let icon = AppIcon.image {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 96, height: 96)
                    }
                    Text("No connections").font(.title3.weight(.semibold))
                    Button("Add R2 connection", action: model.addConnection)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                if let icon = AppIcon.image {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 42, height: 42)
                }
                Text("R2 Desk").font(.title3.weight(.semibold))
            }.padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 24)
            Text("CONNECTIONS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 18)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.connections) { connection in
                        connectionRow(name: connection.name, icon: "externaldrive", id: connection.id)
                            .contextMenu {
                                Button("Open in New Tab") { model.openTab(connectionID: connection.id) }
                                Button("Edit Connection…") { model.edit(connection) }.disabled(model.busy)
                                Divider()
                                Button("Remove Connection…", role: .destructive) { model.removeConnection(connection) }.disabled(model.busy)
                            }
                    }
                    Button(action: model.addConnection) {
                        Label("Add R2 connection", systemImage: "plus.circle").font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }.buttonStyle(.plain).foregroundStyle(.orange).padding(.top, 5)
                }.padding(.horizontal, 8).padding(.top, 8)
            }
            Spacer()
        }.background(.background.opacity(0.35))
    }
    private func connectionRow(name: String, icon: String, id: UUID) -> some View {
        let selected = model.current?.connectionID == id
        return Button { model.selectConnection(id) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title3).foregroundStyle(selected ? .orange : .secondary).frame(width: 24)
                Text(name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
                if selected { Circle().fill(.orange).frame(width: 6, height: 6) }
            }.padding(10).contentShape(Rectangle())
                .background(selected ? Color.orange.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.tabs) { tab in TabButton(tab: tab).environmentObject(model) }
                }.padding(8)
            }
            Button(action: model.duplicateTab) { Image(systemName: "plus").padding(9) }
                .buttonStyle(.plain).help("New tab").padding(.trailing, 8)
        }.background(.bar)
    }
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if model.busy {
                    ProgressView(value: model.progress).frame(width: 110)
                    Text(model.status).lineLimit(1)
                    Spacer()
                    Button("Stop", action: model.cancel).controlSize(.small)
                } else {
                    Circle().fill(model.status == "Operation failed" ? .red : .green).frame(width: 5, height: 5)
                    Text(model.status)
                    Spacer()
                    if let tab = model.current {
                        let count = tab.bucket == nil ? tab.visibleBuckets.count : tab.visibleItems.count
                        let unit = tab.bucket == nil ? (count == 1 ? "bucket" : "buckets") : (count == 1 ? "item" : "items")
                        Text("\(count) " + unit + (tab.selection.isEmpty ? "" : " · \(tab.selection.count) selected"))
                    }
                }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 35)
        }.background(.bar)
    }
}

private struct PreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: PreviewDocument
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(document.url.lastPathComponent).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            FilePreview(url: document.url)
        }.frame(width: 700, height: 550)
    }
}

private struct FilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true; view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: Void) { view.previewItem = nil; view.close() }
}

private struct TabButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tab: FolderTab
    @State private var hovered = false
    private var selected: Bool { model.activeTabID == tab.id }
    private var title: String { tab.bucket == nil ? model.connectionName(tab.connectionID) : tab.title }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button { model.activeTabID = tab.id } label: {
                HStack(spacing: 7) {
                    Image(systemName: tab.bucket == nil ? "externaldrive" : "folder").foregroundStyle(.orange)
                    Text(title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .padding(.trailing, model.tabs.count > 1 ? 36 : 12)
                .padding(.vertical, 10)
                .frame(minWidth: 130, maxWidth: 190, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(selected ? "Selected" : "")
            if model.tabs.count > 1 {
                Button { model.closeTab(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(TabCloseButtonStyle()).padding(.trailing, 5)
                    .help("Close tab").accessibilityLabel("Close \(title)")
            }
        }.font(.callout)
            .background(selected ? Color(nsColor: .controlBackgroundColor) : hovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7).fill(selected && hovered ? Color.primary.opacity(0.04) : .clear)
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.primary.opacity(0.08) : .clear)
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
            .help("\(model.connectionName(tab.connectionID))/\(tab.bucket.map { $0 + "/" } ?? "")\(tab.prefix)")
    }
}

private struct TabCloseButtonStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(hovered ? .primary : .secondary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : hovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 4))
            .onHover { hovered = $0 }
    }
}

struct FolderView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tab: FolderTab
    @State private var sort = [KeyPathComparator(\RemoteItem.name)]
    @State private var showName = false
    @State private var renameItem: RemoteItem?
    @State private var name = ""
    @State private var targeted = false

    private var sortedItems: [RemoteItem] {
        tab.visibleItems.sorted(using: sort).sorted { $0.isFolder && !$1.isFolder }
    }
    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            ZStack {
                Table(sortedItems, selection: $tab.selection, sortOrder: $sort) {
                    TableColumn("Name", value: \.name) { item in
                        HStack(spacing: 10) {
                            Image(systemName: icon(item)).font(.system(size: 19)).foregroundStyle(item.isFolder ? .orange : .secondary).frame(width: 24)
                            Text(item.name).lineLimit(1).padding(.vertical, 6)
                        }
                    }.width(min: 220, ideal: 380)
                    TableColumn("Size", value: \.size) { item in
                        Text(item.isFolder ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).foregroundStyle(.secondary)
                    }.width(90)
                    TableColumn("Modified", value: \.modificationSortDate) { item in
                        Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—").foregroundStyle(.secondary)
                    }.width(min: 140, ideal: 180)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    let items = tab.visibleItems.filter { ids.contains($0.key) }
                    if let item = items.first, items.count == 1 {
                        if item.isFolder {
                            Button("Open Folder") { model.navigate(item.key, tab: tab) }
                            Button("Open in New Tab") {
                                if let bucket = tab.bucket { model.openTab(connectionID: tab.connectionID, location: .folder(bucket: bucket, prefix: item.key)) }
                            }
                        } else {
                            Button("Quick Look") { model.previewFile(item, tab: tab) }.disabled(model.busy)
                            Button("Rename…") { renameItem = item; name = item.name; showName = true }.disabled(model.busy)
                        }
                    }
                    if !items.isEmpty {
                        Divider()
                        Button("Download…") { tab.selection = ids; model.downloadSelection() }.disabled(model.busy)
                        Button("Delete…", role: .destructive) { tab.selection = ids; model.deleteSelection() }.disabled(model.busy)
                    } else {
                        Button("New Folder…") { beginFolder() }.disabled(model.busy)
                        Button("Upload…", action: model.chooseUpload).disabled(model.busy)
                    }
                } primaryAction: { ids in
                    if let item = tab.visibleItems.first(where: { ids.contains($0.key) }) { model.open(item, tab: tab) }
                }
                .onKeyPress(.space) {
                    if let item = tab.selectedItems.first, tab.selectedItems.count == 1, !model.busy {
                        model.open(item, tab: tab); return .handled
                    }
                    return .ignored
                }
                if tab.loading && tab.items.isEmpty {
                    stateView(icon: "icloud", title: "Open folder…", detail: "") { ProgressView().controlSize(.small) }
                } else if let error = tab.error {
                    stateView(icon: "exclamationmark.icloud", title: "Folder could not be opened", detail: error) {
                        Button("Try Again") { model.reload(tab) }
                        Button("Edit Connection") {
                            if let connection = model.connection(tab.connectionID) { model.edit(connection) }
                        }
                    }
                } else if tab.visibleItems.isEmpty {
                    stateView(icon: tab.search.isEmpty ? "folder" : "magnifyingglass", title: tab.search.isEmpty ? "This folder is empty" : "No matching files",
                              detail: "") {
                        if tab.search.isEmpty { Button("Upload Files", action: model.chooseUpload).disabled(model.busy) }
                        else { Button("Clear Search") { tab.search = "" } }
                    }
                }
                if targeted {
                    RoundedRectangle(cornerRadius: 12).fill(.orange.opacity(0.10)).overlay {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(.orange, style: StrokeStyle(lineWidth: 2, dash: [8]))
                        Label("Upload to this folder", systemImage: "arrow.up.doc").font(.title3).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }.padding(10).allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard !model.busy else { return false }
                // Keep the drop order. Do not upload until every provider has returned its URL.
                Task {
                    var urls: [URL] = []
                    for provider in providers {
                        let url: URL? = await withCheckedContinuation { continuation in
                            _ = provider.loadObject(ofClass: URL.self) { value, _ in continuation.resume(returning: value) }
                        }
                        if let url { urls.append(url) }
                    }
                    if urls.count == providers.count { model.upload(urls, tab: tab) }
                    else { model.alert = "Some dropped files could not be read. Use the Upload button." }
                }
                return true
            }
        }
        .sheet(isPresented: $showName) {
            VStack(alignment: .leading, spacing: 16) {
                Text(renameItem == nil ? "New Folder" : "Rename File").font(.title2.weight(.semibold))
                TextField(renameItem == nil ? "Folder name" : "File name", text: $name).textFieldStyle(.roundedBorder)
                    .onSubmit { submitName() }
                HStack {
                    Spacer()
                    Button("Cancel") { showName = false }.keyboardShortcut(.cancelAction)
                    Button(renameItem == nil ? "Create" : "Rename") { submitName() }
                        .keyboardShortcut(.defaultAction).disabled(name.isEmpty)
                }
            }.padding(24).frame(width: 400)
        }
    }
    private var pathBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    Button("Buckets") { model.navigate(.buckets, tab: tab) }.buttonStyle(.plain)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Button(tab.bucket ?? "") { model.navigate("", tab: tab) }.buttonStyle(.plain).help("Bucket root")
                    let parts = tab.prefix.split(separator: "/").map(String.init)
                    ForEach(parts.indices, id: \.self) { index in
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Button(parts[index]) { model.navigate(parts.prefix(index + 1).joined(separator: "/") + "/", tab: tab) }.buttonStyle(.plain).lineLimit(1)
                    }
                }.font(.callout)
            }
            if tab.loading { ProgressView().controlSize(.mini).padding(.trailing, 8) }
            Button { beginFolder() } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.borderless).disabled(model.busy).help("New folder")
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search this folder", text: $tab.search).textFieldStyle(.plain)
                    .onChange(of: tab.search) { _, _ in tab.selection.formIntersection(Set(tab.visibleItems.map(\.key))) }
                if !tab.search.isEmpty { Button { tab.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }.font(.callout).padding(7).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6)).frame(width: 210)
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }
    private func stateView<Actions: View>(icon: String, title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44, weight: .light)).foregroundStyle(.orange)
            Text(title).font(.title3.weight(.semibold))
            if !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            }
            HStack { actions() }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor))
    }
    private func icon(_ item: RemoteItem) -> String {
        if item.isFolder { return "folder.fill" }
        let type = UTType(filenameExtension: (item.name as NSString).pathExtension)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .audio) == true { return "music.note" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        return "doc.text"
    }
    private func beginFolder() { renameItem = nil; name = ""; showName = true }
    private func submitName() {
        do { try FilePaths.validateName(name) } catch { model.alert = error.localizedDescription; return }
        showName = false
        if let item = renameItem { model.rename(item, name: name, tab: tab) }
        else { model.createFolder(name, tab: tab) }
    }
}
