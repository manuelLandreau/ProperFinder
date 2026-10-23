import Foundation

public struct PathTarget: Equatable, Sendable {
    public let folder: URL
    public let selection: URL?
}

public func resolvePathInput(_ text: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             fileManager: FileManager = .default) throws -> PathTarget {
    let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var path = input
    if path == "~" {
        path = home.path
    } else if path.hasPrefix("~/") {
        path = home.path + path.dropFirst()
    }
    guard path.hasPrefix("/") else { throw FinderError.relativePath(input) }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw FinderError.notFound(input) }
    let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    if isDirectory.boolValue && !isPackage {
        return PathTarget(folder: URL(fileURLWithPath: url.path, isDirectory: true), selection: nil)
    }
    return PathTarget(folder: URL(fileURLWithPath: url.deletingLastPathComponent().path, isDirectory: true), selection: url)
}
