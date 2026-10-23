import Foundation

public struct SidebarLocation: Hashable, Sendable {
    public let accessibilityID: String
    public let name: String
    public let url: URL
    public let symbol: String
    public let detail: String?
    public let isEjectable: Bool

    public init(accessibilityID: String, name: String, url: URL, symbol: String, detail: String? = nil, isEjectable: Bool = false) {
        self.accessibilityID = accessibilityID
        self.name = name
        self.url = url
        self.symbol = symbol
        self.detail = detail
        self.isEjectable = isEjectable
    }
}

public func standardLocations(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
                              fileManager: FileManager = .default) -> [SidebarLocation] {
    [
        SidebarLocation(accessibilityID: "sidebar.home", name: home.lastPathComponent, url: home, symbol: "house"),
        SidebarLocation(accessibilityID: "sidebar.desktop", name: String(localized: "Desktop"),
                        url: home.appendingPathComponent("Desktop", isDirectory: true), symbol: "menubar.dock.rectangle"),
        SidebarLocation(accessibilityID: "sidebar.documents", name: String(localized: "Documents"),
                        url: home.appendingPathComponent("Documents", isDirectory: true), symbol: "doc"),
        SidebarLocation(accessibilityID: "sidebar.downloads", name: String(localized: "Downloads"),
                        url: home.appendingPathComponent("Downloads", isDirectory: true), symbol: "arrow.down.circle"),
        SidebarLocation(accessibilityID: "sidebar.applications", name: String(localized: "Applications"),
                        url: applications, symbol: "square.grid.3x3"),
    ].filter { fileManager.fileExists(atPath: $0.url.path) }
}

public func trashLocation(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SidebarLocation {
    SidebarLocation(accessibilityID: "sidebar.trash", name: String(localized: "Trash"),
                    url: home.appendingPathComponent(".Trash", isDirectory: true), symbol: "trash")
}

/// Directory names under ~/Library/CloudStorage are "<Provider>-<account>", e.g. "GoogleDrive-a@b.c" or "OneDrive-Personal".
public func parseCloudStorageName(_ name: String) -> (provider: String, account: String?) {
    let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
    let providers = ["GoogleDrive": "Google Drive"]
    let account = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
    return (providers[parts.first ?? name] ?? parts.first ?? name, account)
}

public func cloudLocations(home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) -> [SidebarLocation] {
    var locations: [SidebarLocation] = []
    let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    if fileManager.fileExists(atPath: iCloud.path) {
        locations.append(SidebarLocation(accessibilityID: "sidebar.cloud.com~apple~CloudDocs", name: String(localized: "iCloud Drive"),
                                         url: iCloud, symbol: "icloud"))
    }
    let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
    let providers = (try? fileManager.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
    for url in providers.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        let (provider, account) = parseCloudStorageName(url.lastPathComponent)
        locations.append(SidebarLocation(accessibilityID: "sidebar.cloud.\(url.lastPathComponent)", name: provider,
                                         url: storage.appendingPathComponent(url.lastPathComponent, isDirectory: true),
                                         symbol: "cloud", detail: account))
    }
    return locations
}

public func mountedVolumes(fileManager: FileManager = .default) -> [SidebarLocation] {
    let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
    let urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: .skipHiddenVolumes) ?? []
    return urls.compactMap { url in
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsBrowsable != false,
              values.volumeIsRootFileSystem != true, url.path.hasPrefix("/Volumes/") else { return nil }
        let name = values.volumeLocalizedName ?? url.lastPathComponent
        let ejectable = values.volumeIsEjectable == true || values.volumeIsRemovable == true
        return SidebarLocation(accessibilityID: "sidebar.volume.\(name)", name: name, url: url,
                               symbol: ejectable ? "externaldrive" : "internaldrive", isEjectable: ejectable)
    }
}

public final class FavoritesStore {
    private let defaults: UserDefaults
    private let key = "favorites"
    public private(set) var urls: [URL]

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        urls = (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public var locations: [SidebarLocation] {
        urls.map { SidebarLocation(accessibilityID: "sidebar.favorite.\($0.lastPathComponent)", name: $0.lastPathComponent, url: $0, symbol: "folder") }
    }

    public func contains(_ url: URL) -> Bool {
        urls.contains { $0.path == url.standardizedFileURL.path }
    }

    public func add(_ url: URL) {
        guard !contains(url) else { return }
        urls.append(URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true))
        save()
    }

    public func remove(_ url: URL) {
        urls.removeAll { $0.path == url.standardizedFileURL.path }
        save()
    }

    /// Same semantics as SwiftUI's onMove: `destination` is an index in the list before the move.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { urls[$0] }
        for index in source.reversed() { urls.remove(at: index) }
        urls.insert(contentsOf: moving, at: destination - source.count(in: 0..<destination))
        save()
    }

    private func save() {
        defaults.set(urls.map(\.path), forKey: key)
    }
}
