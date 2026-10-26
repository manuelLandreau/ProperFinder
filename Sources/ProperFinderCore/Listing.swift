import Foundation
import UniformTypeIdentifiers

public struct FileItem: Hashable, Identifiable, Sendable {
    public let url: URL
    public let name: String
    /// Packages (.app, .photoslibrary…) are not folders: they open instead of being browsed, like in Finder.
    public let isFolder: Bool
    public let dateModified: Date?
    public let size: Int64?
    public let kind: String
    public var id: URL { url }

    static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .contentTypeKey,
    ]

    public init(url: URL) throws { try self.init(url: url, valuesFrom: url) }

    init(url: URL, valuesFrom source: URL) throws {
        let values = try source.resourceValues(forKeys: Self.keys)
        var isDirectory = values.isDirectory == true
        var isPackage = values.isPackage == true
        if values.isSymbolicLink == true, let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
            isDirectory = target.isDirectory == true
            isPackage = target.isPackage == true
        }
        self.url = url
        name = url.lastPathComponent
        isFolder = isDirectory && !isPackage
        dateModified = values.contentModificationDate
        size = isDirectory ? nil : values.fileSize.map(Int64.init)
        // UTType descriptions are lowercase ("folder", "text"); Finder capitalizes its Kind column.
        kind = (values.contentType?.localizedDescription).map { $0.prefix(1).uppercased() + $0.dropFirst() }
            ?? (isFolder ? String(localized: "Folder") : String(localized: "Document"))
    }
}

public enum SortKey: CaseIterable, Sendable {
    case name, dateModified, size, kind
}

public func listDirectory(_ directory: URL, showHidden: Bool, sortedBy key: SortKey = .name, ascending: Bool = true,
                          fileManager: FileManager = .default) throws -> [FileItem] {
    let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(FileItem.keys),
                                                   options: showHidden ? [] : .skipsHiddenFiles)
    // contentsOfDirectory answers /private/var/... for a /var/... folder: re-root items on the caller's URL so they match the
    // URLs built from it (item to select after creation), while reading values from the returned URLs that hold the prefetch.
    // An entry that vanished before its stat is dropped rather than failing the whole folder.
    let items = urls.compactMap { url in
        try? FileItem(url: directory.appendingPathComponent(url.lastPathComponent, isDirectory: url.hasDirectoryPath), valuesFrom: url)
    }
    return sortItems(items, by: key, ascending: ascending)
}

public func sortItems(_ items: [FileItem], by key: SortKey, ascending: Bool) -> [FileItem] {
    items.sorted { a, b in
        if a.isFolder != b.isFolder { return a.isFolder }
        let order: ComparisonResult = switch key {
        case .name: a.name.localizedStandardCompare(b.name)
        case .dateModified: compare(a.dateModified ?? .distantPast, b.dateModified ?? .distantPast)
        case .size: compare(a.size ?? -1, b.size ?? -1)
        case .kind: a.kind.localizedStandardCompare(b.kind)
        }
        if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
    a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
}

public func filterItems(_ items: [FileItem], matching query: String) -> [FileItem] {
    let query = query.trimmingCharacters(in: .whitespaces)
    return query.isEmpty ? items : items.filter { $0.name.localizedStandardContains(query) }
}

// Logical bytes, Finder's first figure, not the allocated size on disk.
public func directorySize(_ url: URL) async -> (bytes: Int64, items: Int)? {
    guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
    var bytes: Int64 = 0, items = 0
    while let child = walk.nextObject() as? URL {
        if Task.isCancelled { return nil }
        items += 1
        bytes += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
    return (bytes, items)
}

public func availableCapacity(at url: URL) -> Int64? {
    try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
}
