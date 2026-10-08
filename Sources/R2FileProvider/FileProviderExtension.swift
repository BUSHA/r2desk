import FileProvider
import R2Core
import R2FinderShared

@objc(R2DeskFileProviderExtension)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderServicing {
    private let drive: FinderDrive
    private let control: DriveControlService
    required init(domain: NSFileProviderDomain) {
        let drive = FinderDrive(domain: domain)
        self.drive = drive; control = DriveControlService(drive: drive)
        super.init()
    }
    func invalidate() { control.stop(); Task { await drive.invalidate() } }
    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        perform({ try await self.drive.item(identifier) }) { result in
            switch result {
            case .success(let item): completionHandler(item, nil)
            case .failure(let error): completionHandler(nil, error)
            }
        }
    }
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1000)
        return perform(progress: progress, { try await self.drive.fetch(itemIdentifier, version: requestedVersion, progress: progress) }) { result in
            switch result {
            case .success(let (url, item)): completionHandler(url, item, nil)
            case .failure(let error): completionHandler(nil, nil, error)
            }
        }
    }
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1000)
        return perform(progress: progress, { try await self.drive.create(template: itemTemplate, contents: url, options: options, progress: progress) }) { result in
            switch result {
            case .success(let item): completionHandler(item, [], false, nil)
            case .failure(let error): completionHandler(nil, [], false, error)
            }
        }
    }
    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1000)
        return perform(progress: progress, {
            try await self.drive.modify(template: item, version: version, fields: changedFields, contents: newContents, progress: progress)
        }) { result in
            switch result {
            case .success(let item): completionHandler(item, [], false, nil)
            case .failure(let error): completionHandler(nil, [], false, error)
            }
        }
    }
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        perform({ try await self.drive.delete(id: identifier, version: version, recursive: options.contains(.recursive)) }) { result in
            switch result {
            case .success: completionHandler(nil)
            case .failure(let error): completionHandler(error)
            }
        }
    }
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet { return DriveEnumerator(drive: drive, container: nil) }
        return DriveEnumerator(drive: drive, container: containerItemIdentifier)
    }
    func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier,
                                 completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void) -> Progress {
        completionHandler(itemIdentifier == .rootContainer ? [control] : [], nil); return Progress()
    }
    private func perform<T>(progress: Progress = Progress(totalUnitCount: 1), _ body: @escaping () async throws -> T,
                            completion: @escaping (Result<T, Error>) -> Void) -> Progress {
        let task = Task {
            do { completion(.success(try await body())) }
            catch { completion(.failure(FinderDrive.error(error))) }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}

private final class DriveEnumerator: NSObject, NSFileProviderEnumerator {
    private let drive: FinderDrive
    private let container: NSFileProviderItemIdentifier?
    private var enumerationAnchor: Data?
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var invalidated = false
    init(drive: FinderDrive, container: NSFileProviderItemIdentifier?) { self.drive = drive; self.container = container }
    private func remember(_ anchor: Data) { lock.lock(); enumerationAnchor = anchor; lock.unlock() }
    private func remembered() -> Data? { lock.lock(); defer { lock.unlock() }; return enumerationAnchor }
    private func scope() async throws -> (String?, Bool) {
        guard let container else { return (nil, false) }
        let item = try await drive.item(container)
        return (item.remote.key, !item.remote.isFolder)
    }
    func invalidate() {
        lock.lock(); invalidated = true; let pending = tasks; tasks.removeAll(); lock.unlock()
        for task in pending { task.cancel() }
    }
    private func run(_ body: @escaping () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { return }
        tasks.append(Task { await body() })
    }
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        run {
            do {
                let (prefix, document) = try await self.scope()
                let (items, anchor) = try await self.drive.enumeration(prefix: document ? nil : prefix)
                try Task.checkCancellation()
                self.remember(anchor)
                if !document {
                    for start in stride(from: 0, to: items.count, by: 200) {
                        observer.didEnumerate(Array(items[start..<min(start + 200, items.count)]))
                    }
                }
                observer.finishEnumerating(upTo: nil)
            } catch { observer.finishEnumeratingWithError(FinderDrive.error(error)) }
        }
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        run {
            let anchor: Data
            if let remembered = self.remembered() { anchor = remembered }
            else { anchor = await self.drive.snapshot().1 }
            completionHandler(NSFileProviderSyncAnchor(rawValue: anchor))
        }
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        run {
            do {
                let (prefix, document) = try await self.scope()
                if let prefix, !document { _ = try await self.drive.listing(prefix: prefix) }
                let (deleted, updated, next) = try await self.drive.changeItems(since: anchor.rawValue, prefix: document ? nil : prefix)
                try Task.checkCancellation()
                self.remember(next)
                observer.didDeleteItems(withIdentifiers: document ? deleted.filter { $0 == self.container } : deleted)
                observer.didUpdate(document ? updated.filter { $0.itemIdentifier == self.container } : updated)
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(rawValue: next), moreComing: false)
            } catch { observer.finishEnumeratingWithError(FinderDrive.error(error)) }
        }
    }
}

private final class DriveControlService: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, FinderControlProtocol {
    let serviceName = NSFileProviderServiceName(FinderControl.serviceName)
    var isRestricted: Bool { true }
    private let drive: FinderDrive
    private let listener = NSXPCListener.anonymous()
    init(drive: FinderDrive) { self.drive = drive; super.init(); listener.delegate = self; listener.resume() }
    func stop() { listener.invalidate() }
    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint { listener.endpoint }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: FinderControlProtocol.self)
        connection.exportedObject = self; connection.resume(); return true
    }
    func configure(_ payload: Data, reply: @escaping (NSError?) -> Void) {
        Task { do { try await drive.configure(payload); reply(nil) } catch { reply(FinderDrive.error(error) as NSError) } }
    }
    func refresh(reply: @escaping (NSError?) -> Void) {
        Task { do { try await drive.refresh(); reply(nil) } catch { reply(FinderDrive.error(error) as NSError) } }
    }
    func revoke(reply: @escaping (NSError?) -> Void) {
        Task { do { try await drive.revoke(); reply(nil) } catch { reply(FinderDrive.error(error) as NSError) } }
    }
}
