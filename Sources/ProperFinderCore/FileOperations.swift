import Foundation

public enum FinderError: LocalizedError, Equatable {
    case emptyName
    case invalidName(String)
    case nameTaken(String)
    case moveIntoItself(String)
    case relativePath(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "The name can't be empty.")
        case .invalidName(let name): String(localized: "“\(name)” is not a valid name. Names can't contain “/” or “:”.")
        case .nameTaken(let name): String(localized: "The name “\(name)” is already taken. Please choose a different name.")
        case .moveIntoItself(let name): String(localized: "“\(name)” can't be moved or copied into itself.")
        case .relativePath(let path): String(localized: "“\(path)” is not an absolute path.")
        case .notFound(let path): String(localized: "The folder “\(path)” can't be found.")
        }
    }
}

/// lstat-based, so a broken symlink still counts as taken (fileExists follows links and would say no).
func itemExists(_ url: URL, _ fileManager: FileManager) -> Bool {
    (try? fileManager.attributesOfItem(atPath: url.path)) != nil
}

public func uniqueName(for name: String, in directory: URL, fileManager: FileManager = .default) -> String {
    guard itemExists(directory.appendingPathComponent(name), fileManager) else { return name }
    let ext = (name as NSString).pathExtension
    let base = (name as NSString).deletingPathExtension
    var n = 2
    while true {
        let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        if !itemExists(directory.appendingPathComponent(candidate), fileManager) { return candidate }
        n += 1
    }
}

public func createFolder(in directory: URL, named name: String = String(localized: "untitled folder"),
                         fileManager: FileManager = .default) throws -> URL {
    let url = directory.appendingPathComponent(uniqueName(for: name, in: directory, fileManager: fileManager), isDirectory: true)
    try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

public func createFile(in directory: URL, named name: String = String(localized: "untitled.txt"),
                       fileManager: FileManager = .default) throws -> URL {
    let url = directory.appendingPathComponent(uniqueName(for: name, in: directory, fileManager: fileManager), isDirectory: false)
    try Data().write(to: url, options: .withoutOverwriting)
    return url
}

public func validateName(_ name: String) throws {
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw FinderError.emptyName }
    if name.contains("/") || name.contains(":") || name == "." || name == ".." { throw FinderError.invalidName(name) }
}

@discardableResult
public func renameItem(at url: URL, to newName: String, fileManager: FileManager = .default) throws -> URL {
    try validateName(newName)
    if newName == url.lastPathComponent { return url }
    let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
    // On a case-insensitive volume "readme.md" -> "README.md" finds the destination taken by the item itself.
    if itemExists(destination, fileManager) && !isSameItem(url, destination) { throw FinderError.nameTaken(newName) }
    try fileManager.moveItem(at: url, to: destination)
    return destination
}

private func isSameItem(_ a: URL, _ b: URL) -> Bool {
    let ids = [a, b].map { try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject }
    return ids[0] != nil && ids[0] == ids[1]
}

private func resolvedPath(_ url: URL) -> String {
    url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
}

private func refuseIntoItself(_ sources: [URL], _ directory: URL) throws {
    let target = directory.resolvingSymlinksInPath().standardizedFileURL.path
    for source in sources {
        let path = resolvedPath(source)
        if target == path || target.hasPrefix(path + "/") { throw FinderError.moveIntoItself(source.lastPathComponent) }
    }
}

public func copyItems(_ urls: [URL], to directory: URL, fileManager: FileManager = .default) throws -> [URL] {
    try refuseIntoItself(urls, directory)
    return try urls.map { source in
        let destination = directory.appendingPathComponent(uniqueName(for: source.lastPathComponent, in: directory, fileManager: fileManager))
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }
}

/// Moving an item to the folder it is already in is a no-op, not a "keep both" duplicate.
public func moveItems(_ urls: [URL], to directory: URL, fileManager: FileManager = .default) throws -> [URL] {
    try refuseIntoItself(urls, directory)
    let target = directory.resolvingSymlinksInPath().standardizedFileURL.path
    return try urls.map { source in
        if source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == target { return source }
        let destination = directory.appendingPathComponent(uniqueName(for: source.lastPathComponent, in: directory, fileManager: fileManager))
        try fileManager.moveItem(at: source, to: destination)
        return destination
    }
}

public func dropItems(_ urls: [URL], into directory: URL, fileManager: FileManager = .default) throws -> [URL] {
    try refuseIntoItself(urls, directory)
    return try urls.flatMap { url in
        // The folder may be a symlink to another volume: its own volume is not where the items land.
        isSameVolume(url, directory.resolvingSymlinksInPath())
            ? try moveItems([url], to: directory, fileManager: fileManager)
            : try copyItems([url], to: directory, fileManager: fileManager)
    }
}

public func isSameVolume(_ a: URL, _ b: URL) -> Bool {
    let ids = [a, b].map { try? $0.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject }
    return ids[0] != nil && ids[0] == ids[1]
}

@discardableResult
public func trashItems(_ urls: [URL], fileManager: FileManager = .default) throws -> [URL] {
    try urls.map { url in
        var trashed: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &trashed)
        return (trashed as URL?) ?? url
    }
}

/// Only the boot volume's ~/.Trash: per-volume .Trashes folders are left to Finder.
public func emptyTrash(at trash: URL, fileManager: FileManager = .default) throws {
    for url in try fileManager.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
        try fileManager.removeItem(at: url)
    }
}
