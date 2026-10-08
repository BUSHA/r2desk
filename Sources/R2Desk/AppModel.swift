import SwiftUI
import AppKit
import Combine
import R2Core

@MainActor
final class FolderTab: ObservableObject, Identifiable {
    let id: UUID
    let connectionID: UUID
    @Published private(set) var location: BrowserLocation { didSet { onSessionChange?() } }
    @Published var items: [RemoteItem] = []
    @Published var buckets: [RemoteBucket] = []
    @Published var selection = Set<String>() { didSet { onSessionChange?() } }
    @Published var search = "" { didSet { onSessionChange?() } }
    @Published var loading = false
    @Published var error: String?
    private var history: BrowserHistory
    private var loadTask: Task<Void, Never>?
    private var requestID = UUID()
    var onSessionChange: (() -> Void)?
    var savedState: SavedBrowserTab {
        SavedBrowserTab(id: id, connectionID: connectionID, history: history, search: search, selection: selection)
    }
    var prefix: String { location.prefix }
    var bucket: String? { location.bucket }
    var title: String { location.title }
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    var visibleBuckets: [RemoteBucket] { buckets.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    var visibleItems: [RemoteItem] { items.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    var selectedItems: [RemoteItem] { visibleItems.filter { selection.contains($0.key) } }
    init(connectionID: UUID, location: BrowserLocation = .buckets) {
        id = UUID(); self.connectionID = connectionID; self.location = location; history = BrowserHistory(location: location)
    }
    init(savedState: SavedBrowserTab) {
        id = savedState.id; connectionID = savedState.connectionID; history = savedState.history
        location = history.location; search = savedState.search; selection = savedState.selection
    }
    func navigate(_ location: BrowserLocation) -> Bool {
        guard history.navigate(location) else { return false }
        resetLocation(); return true
    }
    func back() -> Bool {
        guard history.back() else { return false }; resetLocation(); return true
    }
    func forward() -> Bool {
        guard history.forward() else { return false }; resetLocation(); return true
    }
    private func resetLocation() {
        loadTask?.cancel(); requestID = UUID()
        location = history.location; selection = []; search = ""; items = []; buckets = []; error = nil
    }
    func load(_ client: S3Client) {
        loadTask?.cancel()
        let generation = UUID(); requestID = generation
        let location = self.location
        loading = true; error = nil
        loadTask = Task {
            do {
                if location.bucket == nil {
                    let result = try await client.listBuckets()
                    guard !Task.isCancelled, requestID == generation else { return }
                    buckets = result; selection.formIntersection(Set(result.map(\.name)))
                } else {
                    let result = try await client.list(prefix: location.prefix, recursive: false)
                    guard !Task.isCancelled, requestID == generation else { return }
                    items = result; selection.formIntersection(Set(result.map(\.key)))
                }
            } catch {
                guard !Task.isCancelled, requestID == generation else { return }
                self.error = error.localizedDescription
            }
            if requestID == generation { loading = false }
        }
    }
    func showBuckets(_ buckets: [RemoteBucket]) {
        loadTask?.cancel(); requestID = UUID(); self.buckets = buckets; loading = false; error = nil
        selection.formIntersection(Set(buckets.map(\.name)))
    }
    func close() { loadTask?.cancel() }
}

struct TransferRecord: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let succeeded: Bool
    let date = Date()
}

struct PreviewDocument: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class AppModel: ObservableObject {
    @Published var connections: [Connection] = []
    @Published var tabs: [FolderTab] = [] { didSet { saveSession() } }
    @Published var activeTabID: UUID? { didSet { saveSession() } }
    @Published var showConnection = false
    @Published var editingConnection: Connection?
    let finder = FinderDriveManager()
    @Published var showFinderDrives = false
    private var finderObserver: AnyCancellable?
    @Published var showTransfers = false
    @Published var busy = false
    @Published var status = "Ready"
    @Published var progress = 0.0
    @Published var records: [TransferRecord] = []
    @Published var alert: String?
    @Published var previewDocument: PreviewDocument?
    private struct ClientKey: Hashable {
        let connectionID: UUID
        let bucket: String?
    }
    private var clients: [ClientKey: S3Client] = [:]
    private let clientFactory: (Connection, String?, Credentials) -> S3Client
    private var operation: Task<Void, Never>?
    private var tabObservers: [UUID: AnyCancellable] = [:]
    private var previewFolder: URL?
    private let preferencesKey = "R2Desk.connections.v1"
    private let sessionKey = "R2Desk.session.v1"
    private var restoringSession = true
    var current: FolderTab? { tabs.first { $0.id == activeTabID } }

    init(clientFactory: @escaping (Connection, String?, Credentials) -> S3Client = {
        S3Client(connection: $0, bucket: $1, credentials: $2)
    }) {
        self.clientFactory = clientFactory
        finderObserver = finder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if let data = UserDefaults.standard.data(forKey: preferencesKey),
           let saved = try? JSONDecoder().decode([Connection].self, from: data) { connections = saved }
        if let data = UserDefaults.standard.data(forKey: sessionKey),
           let session = try? JSONDecoder().decode(BrowserSession.self, from: data) {
            var restoredIDs = Set<UUID>()
            for state in session.tabs where connection(state.connectionID) != nil && restoredIDs.insert(state.id).inserted {
                let tab = FolderTab(savedState: state)
                observe(tab); tabs.append(tab)
            }
            activeTabID = tabs.first(where: { $0.id == session.activeTabID })?.id ?? tabs.first?.id
        }
        if tabs.isEmpty, let connection = connections.first { openTab(connectionID: connection.id) }
        else { for tab in tabs { reload(tab) } }
        restoringSession = false
        saveSession()
    }
    func saveSession() {
        guard !restoringSession else { return }
        let session = BrowserSession(tabs: tabs.map(\.savedState), activeTabID: activeTabID)
        do { UserDefaults.standard.set(try JSONEncoder().encode(session), forKey: sessionKey) }
        catch { alert = "The open tabs could not be saved. \(error.localizedDescription)" }
    }
    private func observe(_ tab: FolderTab) {
        tabObservers[tab.id] = tab.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        tab.onSessionChange = { [weak self] in self?.saveSession() }
    }
    func connection(_ id: UUID) -> Connection? { connections.first { $0.id == id } }
    func connectionName(_ id: UUID) -> String { connection(id)?.name ?? "Connection unavailable" }
    func service(for id: UUID, bucket: String?) throws -> S3Client {
        let key = ClientKey(connectionID: id, bucket: bucket)
        if let client = clients[key] { return client }
        guard let connection = connection(id) else { throw StorageError.message("This connection was removed.") }
        try connection.validate()
        let client = clientFactory(connection, bucket, try Keychain.load(id))
        clients[key] = client; return client
    }
    @discardableResult func openTab(connectionID: UUID, location: BrowserLocation = .buckets, buckets: [RemoteBucket]? = nil) -> FolderTab {
        let tab = FolderTab(connectionID: connectionID, location: location)
        observe(tab)
        tabs.append(tab); activeTabID = tab.id
        if location == .buckets, let buckets { tab.showBuckets(buckets) }
        else { reload(tab) }
        return tab
    }
    func duplicateTab() {
        guard let current else { return }; openTab(connectionID: current.connectionID, location: current.location)
    }
    func closeTab(_ tab: FolderTab) {
        guard tabs.count > 1 else { return }
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.close(); tabObservers.removeValue(forKey: tab.id); tabs.remove(at: index)
        if activeTabID == tab.id { activeTabID = tabs[min(index, tabs.count - 1)].id }
    }
    func selectConnection(_ id: UUID) {
        if let existing = tabs.first(where: { $0.connectionID == id && $0.bucket == nil }) { activeTabID = existing.id; reload(existing) }
        else { openTab(connectionID: id) }
    }
    func reload(_ tab: FolderTab? = nil) {
        guard let tab = tab ?? current else { return }
        do { tab.load(try service(for: tab.connectionID, bucket: tab.bucket)) }
        catch { tab.loading = false; tab.error = error.localizedDescription }
    }
    func navigate(_ prefix: String, tab: FolderTab) {
        guard let bucket = tab.bucket else { return }
        navigate(.folder(bucket: bucket, prefix: prefix), tab: tab)
    }
    func navigate(_ location: BrowserLocation, tab: FolderTab) {
        if tab.navigate(location) { reload(tab) }
    }
    func openBucket(_ bucket: RemoteBucket, tab: FolderTab) {
        navigate(.folder(bucket: bucket.name, prefix: ""), tab: tab)
    }
    func goBack() {
        guard let tab = current else { return }
        if tab.back() { reload(tab) }
    }
    func goForward() {
        guard let tab = current else { return }
        if tab.forward() { reload(tab) }
    }
    func goUp() {
        guard let tab = current, let parent = tab.location.parent else { return }
        navigate(parent, tab: tab)
    }
    func saveConnection(_ connection: Connection, credentials: Credentials, client: S3Client, buckets: [RemoteBucket]) async throws {
        try await finder.validateEdit(connection)
        try Keychain.save(credentials, for: connection.id)
        if let index = connections.firstIndex(where: { $0.id == connection.id }) { connections[index] = connection }
        else { connections.append(connection) }
        clients = clients.filter { $0.key.connectionID != connection.id }
        clients[ClientKey(connectionID: connection.id, bucket: nil)] = client
        UserDefaults.standard.set(try JSONEncoder().encode(connections), forKey: preferencesKey)
        Task { await finder.refresh() }
        for tab in tabs where tab.connectionID == connection.id { reload(tab) }
        if let tab = tabs.first(where: { $0.connectionID == connection.id && $0.bucket == nil }) {
            tab.showBuckets(buckets); activeTabID = tab.id
        } else { openTab(connectionID: connection.id, buckets: buckets) }
    }
    func removeConnection(_ connection: Connection) {
        guard !busy, confirm("Remove \(connection.name)?", detail: "This removes the saved connection and its keys. Your R2 files stay in the bucket.", action: "Remove") else { return }
        Task {
          do {
            try await finder.remove(connectionID: connection.id)
            try Keychain.remove(connection.id)
            connections.removeAll { $0.id == connection.id }; clients = clients.filter { $0.key.connectionID != connection.id }
            for tab in tabs where tab.connectionID == connection.id { tab.close(); tabObservers.removeValue(forKey: tab.id) }
            tabs.removeAll { $0.connectionID == connection.id }
            UserDefaults.standard.set(try JSONEncoder().encode(connections), forKey: preferencesKey)
            if !tabs.contains(where: { $0.id == activeTabID }) { activeTabID = tabs.first?.id }
          } catch { alert = error.localizedDescription }
        }
    }
    func addToFinder(bucket: String, connectionID: UUID) {
        guard let connection = connection(connectionID) else { return }
        showFinderDrives = true
        Task {
            do { try await finder.add(connection: connection, bucket: bucket) }
            catch { finder.error = error.localizedDescription }
        }
    }
    func openInFinder(bucket: String, connectionID: UUID) {
        Task {
            do { try await finder.open(connectionID: connectionID, bucket: bucket) }
            catch { finder.error = error.localizedDescription; showFinderDrives = true }
        }
    }
    func edit(_ connection: Connection) {
        editingConnection = connection; showConnection = true
    }
    func addConnection() { editingConnection = nil; showConnection = true }
    func cancel() { operation?.cancel(); status = "Stopping…" }

    private func confirm(_ title: String, detail: String, action: String) -> Bool {
        let panel = NSAlert(); panel.messageText = title; panel.informativeText = detail
        panel.alertStyle = .warning; panel.addButton(withTitle: action); panel.addButton(withTitle: "Cancel")
        return panel.runModal() == .alertFirstButtonReturn
    }
    private func run(_ title: String, tab: FolderTab, body: @escaping (any StorageService) async throws -> Void) {
        guard !busy else { return }
        let client: any StorageService
        guard tab.bucket != nil else { alert = "Open a bucket first."; return }
        do { client = try service(for: tab.connectionID, bucket: tab.bucket) } catch { alert = error.localizedDescription; return }
        busy = true; progress = 0; status = title
        operation = Task {
            do {
                try await body(client)
                status = Task.isCancelled ? "Stopped" : "Done"
                records.insert(TransferRecord(title: title, detail: status, succeeded: !Task.isCancelled), at: 0)
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                let detail = cancelled ? "Stopped. Completed files were kept." : error.localizedDescription
                status = cancelled ? "Stopped" : "Operation failed"
                records.insert(TransferRecord(title: title, detail: detail, succeeded: false), at: 0)
                if !cancelled { alert = detail }
            }
            records = Array(records.prefix(50))
            busy = false; operation = nil
            for other in tabs where other.connectionID == tab.connectionID { reload(other) }
        }
    }
    private func transferProgress(base: Double, span: Double) -> TransferProgress {
        { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.busy else { return }
                self.progress = min(1, base + max(0, min(1, fraction)) * span)
            }
        }
    }

    func chooseUpload() {
        guard !busy, let tab = current, tab.bucket != nil else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true; panel.prompt = "Upload"
        panel.begin { [weak self] response in
            Task { @MainActor in if response == .OK { self?.upload(panel.urls, tab: tab) } }
        }
    }
    func upload(_ urls: [URL], tab: FolderTab) {
        let prefix = tab.prefix
        run("Upload files", tab: tab) { [self] client in
            struct Entry { let file: URL?; let key: String }
            var entries: [Entry] = []
            for url in urls {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw StorageError.message("Symbolic links cannot be uploaded. Select the original file.") }
                try FilePaths.validateName(url.lastPathComponent)
                if values.isDirectory == true {
                    let base = prefix + url.lastPathComponent + "/"
                    entries.append(Entry(file: nil, key: base))
                    var enumerationError: Error?
                    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in enumerationError = error; return false }) else {
                        throw StorageError.message("The selected folder could not be read.")
                    }
                    while let child = enumerator.nextObject() as? URL {
                        try Task.checkCancellation()
                        let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                        if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                        let relative = String(child.path.dropFirst(url.path.count + 1))
                        if values.isDirectory == true { entries.append(Entry(file: nil, key: base + relative + "/")) }
                        else if values.isRegularFile == true { entries.append(Entry(file: child, key: base + relative)) }
                    }
                    if let enumerationError { throw enumerationError }
                } else { entries.append(Entry(file: url, key: prefix + url.lastPathComponent)) }
            }
            guard !entries.isEmpty else { return }
            var seen = Set<String>()
            guard entries.allSatisfy({ seen.insert($0.key).inserted }) else {
                throw StorageError.message("Two selected items have the same remote path. Upload them separately.")
            }
            status = "Check existing files…"
            let existing = try await client.list(prefix: prefix, recursive: true)
            let byKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })
            let conflicts = entries.filter { $0.file != nil && byKey[$0.key] != nil }
            if !conflicts.isEmpty {
                let names = conflicts.prefix(5).map { $0.key }.joined(separator: "\n")
                guard confirm("Replace \(conflicts.count) existing file(s)?", detail: names + "\n\nThe old file contents will be replaced.", action: "Replace") else { throw CancellationError() }
            }
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                status = "Upload \(index + 1) of \(entries.count): \(entry.key)"
                if let file = entry.file {
                    if byKey[entry.key] != nil && byKey[entry.key]?.etag == nil { throw StorageError.message("The existing file has no checksum. Refresh and try again.") }
                    try await client.upload(file: file, key: entry.key, replacingETag: byKey[entry.key]?.etag,
                        progress: transferProgress(base: Double(index) / Double(entries.count), span: 1 / Double(entries.count)))
                } else if byKey[entry.key] == nil {
                    try await client.createFolder(key: entry.key)
                }
                progress = Double(index + 1) / Double(entries.count)
            }
        }
    }

    func downloadSelection() {
        guard !busy, let tab = current, !tab.selectedItems.isEmpty else { return }
        let items = tab.selectedItems
        if items.count == 1, !items[0].isFolder {
            let panel = NSSavePanel(); panel.nameFieldStringValue = items[0].name; panel.prompt = "Download"
            panel.begin { [weak self] response in
                Task { @MainActor in
                    guard response == .OK, let url = panel.url, let self else { return }
                    self.run("Download \(items[0].name)", tab: tab) { client in
                        try await client.download(key: items[0].key, to: url, replaceExisting: true, progress: self.transferProgress(base: 0, span: 1))
                    }
                }
            }
        } else {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.canCreateDirectories = true; panel.prompt = "Download here"
            panel.begin { [weak self] response in
                Task { @MainActor in
                    guard response == .OK, let url = panel.url, let self else { return }
                    self.download(items, tab: tab, root: url)
                }
            }
        }
    }
    private func download(_ items: [RemoteItem], tab: FolderTab, root: URL) {
        let prefix = tab.prefix
        run("Download files", tab: tab) { [self] client in
            var objects = items.filter { !$0.isFolder }
            var directories = items.filter(\.isFolder)
            for folder in items where folder.isFolder {
                let nested = try await client.list(prefix: folder.key, recursive: true)
                objects += nested.filter { !$0.isFolder }; directories += nested.filter(\.isFolder)
            }
            let files = try objects.map { item -> (RemoteItem, URL) in
                let path = String(item.key.dropFirst(prefix.count))
                let url = try FilePaths.localURL(root: root, relativeKey: path)
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw StorageError.message("\(path) already exists on your Mac. Select an empty folder for this download.")
                }
                return (item, url)
            }
            let folders = try directories.map {
                try FilePaths.localURL(root: root, relativeKey: String($0.key.dropFirst(prefix.count).dropLast()))
            }
            for url in folders { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            for (index, pair) in files.enumerated() {
                try Task.checkCancellation()
                status = "Download \(index + 1) of \(files.count): \(pair.0.name)"
                try FileManager.default.createDirectory(at: pair.1.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await client.download(key: pair.0.key, to: pair.1,
                    progress: transferProgress(base: Double(index) / Double(files.count), span: 1 / Double(files.count)))
            }
        }
    }
    func open(_ item: RemoteItem, tab: FolderTab) {
        if item.isFolder { navigate(item.key, tab: tab) } else { previewFile(item, tab: tab) }
    }
    func previewFile(_ item: RemoteItem, tab: FolderTab) {
        guard !item.isFolder else { return }
        run("Preview \(item.name)", tab: tab) { [self] client in
            try FilePaths.validateName(item.name)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("R2DeskPreviews/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(item.name)
            do {
                try await client.download(key: item.key, to: url, progress: transferProgress(base: 0, span: 1))
                try Task.checkCancellation()
                clearPreview()
                previewFolder = folder; previewDocument = PreviewDocument(url: url)
            } catch { try? FileManager.default.removeItem(at: folder); throw error }
        }
    }
    func clearPreview() {
        if let previewFolder { try? FileManager.default.removeItem(at: previewFolder) }
        previewFolder = nil
    }
    func createFolder(_ name: String, tab: FolderTab) {
        let key = tab.prefix + name + "/"
        run("Create folder", tab: tab) { client in
            try FilePaths.validateName(name)
            try await client.createFolder(key: key)
        }
    }
    func rename(_ item: RemoteItem, name: String, tab: FolderTab) {
        let key = tab.prefix + name
        run("Rename \(item.name)", tab: tab) { client in
            try FilePaths.validateName(name)
            try await client.rename(item: item, to: key)
        }
    }
    func deleteSelection() {
        guard let tab = current, !tab.selectedItems.isEmpty else { return }
        let selected = tab.selectedItems
        let bucket = tab.bucket ?? ""
        run("Delete files", tab: tab) { [self] client in
            var keys = Set(selected.map(\.key))
            for folder in selected where folder.isFolder {
                let contents = try await client.list(prefix: folder.key, recursive: true)
                keys.formUnion(contents.map(\.key))
            }
            let title: String
            let targets: String
            if selected.count == 1, let item = selected.first {
                title = item.isFolder ? "Delete folder?" : "Delete file?"
                targets = "Delete \(item.isFolder ? "folder" : "file"): /\(item.key)"
            } else {
                title = "Delete selected items?"
                let paths = selected.prefix(5).map { "/\($0.key)" }.joined(separator: "\n")
                let remaining = selected.count > 5 ? "\n…and \(selected.count - 5) more selected items." : ""
                targets = "Delete \(selected.count) selected items:\n\(paths)\(remaining)"
            }
            let detail = "Bucket: \(bucket)\n\(targets)\n\nThis deletes up to \(keys.count) files and folder records. Files inside selected folders are included. R2 has no Trash."
            guard confirm(title, detail: detail, action: "Delete") else { throw CancellationError() }
            let ordered = keys.sorted { $0.count > $1.count }
            for (index, key) in ordered.enumerated() {
                try Task.checkCancellation(); status = "Delete \(index + 1) of \(ordered.count)"
                try await client.delete(key: key); progress = Double(index + 1) / Double(ordered.count)
            }
        }
    }
}
