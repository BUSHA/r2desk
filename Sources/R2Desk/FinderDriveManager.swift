import AppKit
import FileProvider
import Combine
import R2Core
import R2FinderShared

@MainActor
final class FinderDriveManager: ObservableObject {
    struct Drive: Identifiable {
        let domain: NSFileProviderDomain
        let configuration: FinderConfiguration
        var id: String { domain.identifier.rawValue }
        var name: String { domain.displayName }
    }
    @Published private(set) var drives: [Drive] = []
    @Published private(set) var pending = Set<String>()
    @Published private(set) var messages: [String: String] = [:]
    @Published var error: String?
    private var pollTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    var isPackaged: Bool {
        Bundle.main.builtInPlugInsURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("R2DeskFileProvider.appex").path) } ?? false
    }
    init() {
        observer = NotificationCenter.default.addObserver(forName: .fileProviderDomainDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.refresh() }
        }
        pollTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }
    deinit { pollTask?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    func contains(connectionID: UUID, bucket: String) -> Bool {
        drives.contains { $0.configuration.connection.id == connectionID && $0.configuration.bucket == bucket }
    }
    func validateEdit(_ connection: Connection) async throws {
        try await loadDomains()
        for drive in drives where drive.configuration.connection.id == connection.id {
            // Domain configuration binds keys to an exact endpoint. Remove drives before changing it.
            if drive.configuration.connection.accountID != connection.accountID || drive.configuration.connection.jurisdiction != connection.jurisdiction {
                throw StorageError.message("Remove this connection's Finder drives before you change the account or storage location.")
            }
        }
    }
    func add(connection: Connection, bucket: String) async throws {
        guard isPackaged else { throw StorageError.message("Build and open R2 Desk.app to use Finder drives.") }
        let config = FinderConfiguration(connection: connection, bucket: bucket)
        try config.validate()
        let id = config.identifier
        guard !pending.contains(id) else { return }
        pending.insert(id); defer { pending.remove(id) }
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(id), displayName: bucket)
        domain.supportsSyncingTrash = false
        if !contains(connectionID: connection.id, bucket: bucket) { try await NSFileProviderManager.add(domain) }
        try await loadDomains()
        guard let drive = drives.first(where: { $0.id == id }) else { throw NSFileProviderError(.providerNotFound) }
        do { try await configure(drive); try await open(drive) }
        catch {
            messages[id] = message(error)
            if isDisabled(error) { openSettings() }
            else { throw error }
        }
    }
    private func loadDomains() async throws {
        guard isPackaged else { return }
        let registered = try await NSFileProviderManager.domains()
        var result: [Drive] = []
        for domain in registered {
            guard let config = try? FinderConfiguration.parse(identifier: domain.identifier.rawValue) else { continue }
            var active = domain
            if domain.displayName != config.bucket {
                active = NSFileProviderDomain(identifier: domain.identifier, displayName: config.bucket)
                active.supportsSyncingTrash = false
                try await NSFileProviderManager.add(active)
            }
            result.append(Drive(domain: active, configuration: config))
        }
        drives = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        messages = messages.filter { key, _ in drives.contains { $0.id == key } }
    }
    func refresh() async {
        guard isPackaged else { return }
        do {
            try await loadDomains()
            for drive in drives where !pending.contains(drive.id) {
                pending.insert(drive.id)
                do {
                    try await configure(drive)
                    try await call(drive) { proxy, reply in proxy.refresh(reply: reply) }
                    messages[drive.id] = nil
                } catch { messages[drive.id] = message(error) }
                pending.remove(drive.id)
            }
            error = nil
        } catch { self.error = "Finder drives could not be loaded. \(message(error))" }
    }
    func open(_ drive: Drive) async throws {
        guard let manager = NSFileProviderManager(for: drive.domain) else { throw NSFileProviderError(.providerNotFound) }
        NSWorkspace.shared.open(try await manager.getUserVisibleURL(for: .rootContainer))
    }
    func open(connectionID: UUID, bucket: String) async throws {
        guard let drive = drives.first(where: { $0.configuration.connection.id == connectionID && $0.configuration.bucket == bucket }) else { return }
        try await configure(drive); try await open(drive)
    }
    func remove(_ drive: Drive) async throws {
        guard !pending.contains(drive.id) else { throw StorageError.message("The Finder drive is busy. Try again when it is ready.") }
        pending.insert(drive.id); defer { pending.remove(drive.id) }
        // Clear the extension's keys before removing its domain.
        try await call(drive) { proxy, reply in proxy.revoke(reply: reply) }
        do { _ = try await NSFileProviderManager.remove(drive.domain, mode: .preserveDirtyUserData) }
        catch { try? await configure(drive); throw error }
        drives.removeAll { $0.id == drive.id }; messages[drive.id] = nil
    }
    func remove(connectionID: UUID) async throws {
        try await loadDomains()
        for drive in drives where drive.configuration.connection.id == connectionID { try await remove(drive) }
    }
    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    private func configure(_ drive: Drive) async throws {
        let access = FinderAccess(configuration: drive.configuration, credentials: try Keychain.load(drive.configuration.connection.id))
        let payload = try JSONEncoder().encode(access)
        try await call(drive) { proxy, reply in proxy.configure(payload, reply: reply) }
    }
    private func isDisabled(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.Code.domainDisabled.rawValue
    }
    private func message(_ error: Error) -> String {
        if isDisabled(error) { return "Enable R2 Desk in System Settings → General → Login Items & Extensions → File Providers." }
        let value = error as NSError
        if value.domain == NSFileProviderErrorDomain && value.code == NSFileProviderError.Code.providerTranslocated.rawValue {
            return "Move R2 Desk.app to Applications. Then open it again."
        }
        return error.localizedDescription
    }
    private func call(_ drive: Drive, _ body: @escaping (FinderControlProtocol, @escaping (NSError?) -> Void) -> Void) async throws {
        guard let manager = NSFileProviderManager(for: drive.domain),
              let service = try await manager.service(named: NSFileProviderServiceName(FinderControl.serviceName), for: .rootContainer) else {
            throw NSFileProviderError(.providerNotFound)
        }
        let connection = try await service.fileProviderConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: FinderControlProtocol.self)
        connection.resume(); defer { connection.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reply = FinderReply(continuation)
            connection.invalidationHandler = { reply.finish(CocoaError(.xpcConnectionInvalid)) }
            connection.interruptionHandler = { reply.finish(CocoaError(.xpcConnectionInterrupted)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { reply.finish(URLError(.timedOut)) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ reply.finish($0) }) as? FinderControlProtocol else {
                reply.finish(NSFileProviderError(.providerNotFound)); return
            }
            body(proxy) { reply.finish($0) }
        }
    }
}

private final class FinderReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ error: Error?) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        guard let value else { return }
        if let error { value.resume(throwing: error) } else { value.resume() }
    }
}
