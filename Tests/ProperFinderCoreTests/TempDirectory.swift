import Foundation

class TempDirectory {
    let root: URL
    let fm = FileManager.default

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("properfinder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url.resolvingSymlinksInPath()
    }

    deinit {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    func file(_ path: String, _ contents: String = "", modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func exists(_ path: String) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func contents(_ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func names(in path: String = "") -> [String] {
        ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(path).path)) ?? []).sorted()
    }
}
