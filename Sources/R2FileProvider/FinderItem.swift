import FileProvider
import UniformTypeIdentifiers
import R2Core

final class FinderItem: NSObject, NSFileProviderItem {
    let remote: RemoteItem
    let rootName: String?
    private let stableID: String?
    private let stableParentID: String?
    init(_ remote: RemoteItem, identifier: String? = nil, parentIdentifier: String? = nil, rootName: String? = nil) {
        self.remote = remote; self.stableID = identifier; self.stableParentID = parentIdentifier; self.rootName = rootName
    }
    var itemIdentifier: NSFileProviderItemIdentifier {
        rootName == nil ? NSFileProviderItemIdentifier(stableID ?? FinderIdentity.item(remote.key)) : .rootContainer
    }
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        let parent = FinderIdentity.parent(remote.key)
        return parent.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(stableParentID ?? FinderIdentity.item(parent))
    }
    var filename: String { rootName ?? remote.name }
    var contentType: UTType { remote.isFolder ? .folder : (UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data) }
    var documentSize: NSNumber? { remote.isFolder ? nil : NSNumber(value: remote.size) }
    var contentModificationDate: Date? { remote.modified }
    var capabilities: NSFileProviderItemCapabilities {
        if rootName != nil { return [.allowsReading, .allowsAddingSubItems] }
        let common: NSFileProviderItemCapabilities = [.allowsReading, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsTrashing]
        return remote.isFolder ? common.union(.allowsAddingSubItems) : common.union(.allowsWriting)
    }
    var contentPolicy: NSFileProviderContentPolicy { .downloadLazily }
    var itemVersion: NSFileProviderItemVersion {
        let metadata = "writable-v1:\(filename):\(remote.size):\(remote.modified?.timeIntervalSince1970 ?? 0)"
        return NSFileProviderItemVersion(contentVersion: Data((remote.isFolder ? "folder" : (remote.etag ?? "")).utf8), metadataVersion: Data(metadata.utf8))
    }
}
