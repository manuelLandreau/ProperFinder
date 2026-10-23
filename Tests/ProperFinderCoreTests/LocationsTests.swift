import Foundation
import Testing
@testable import ProperFinderCore

final class LocationsTests: TempDirectory {
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }

    @Test func standardLocationsSkipMissingFolders() throws {
        try folder("home/Desktop")
        try folder("home/Downloads")
        try folder("Applications")

        let locations = standardLocations(home: home, applications: root.appendingPathComponent("Applications"))

        #expect(locations.map(\.accessibilityID) == ["sidebar.home", "sidebar.desktop", "sidebar.downloads", "sidebar.applications"])
        #expect(locations[0].name == "home")
        #expect(locations[1].url.path == home.path + "/Desktop")
    }

    @Test func trashIsInTheHomeFolder() {
        #expect(trashLocation(home: home).url.path == home.path + "/.Trash")
        #expect(trashLocation(home: home).accessibilityID == "sidebar.trash")
    }

    @Test(arguments: [
        ("GoogleDrive-a@b.c", "Google Drive", "a@b.c" as String?),
        ("GoogleDrive-first.last@gmail.com", "Google Drive", "first.last@gmail.com"),
        ("OneDrive-Personal", "OneDrive", "Personal"),
        ("OneDrive-Contoso Ltd", "OneDrive", "Contoso Ltd"),
        ("Dropbox", "Dropbox", nil),
        ("Dropbox-Team-Name", "Dropbox", "Team-Name"),
        ("Box-Box", "Box", "Box"),
        ("GoogleDrive-", "Google Drive", nil),
    ])
    func parsesCloudStorageNames(name: String, provider: String, account: String?) {
        let parsed = parseCloudStorageName(name)
        #expect(parsed.provider == provider)
        #expect(parsed.account == account)
    }

    @Test func discoversCloudProvidersAndICloud() throws {
        try folder("home/Library/CloudStorage/OneDrive-Personal")
        try folder("home/Library/CloudStorage/GoogleDrive-a@b.c")
        try folder("home/Library/CloudStorage/.Trash")
        try file("home/Library/CloudStorage/stray.txt")
        try folder("home/Library/Mobile Documents/com~apple~CloudDocs")

        let locations = cloudLocations(home: home)

        #expect(locations.map(\.accessibilityID) == ["sidebar.cloud.com~apple~CloudDocs", "sidebar.cloud.GoogleDrive-a@b.c", "sidebar.cloud.OneDrive-Personal"])
        #expect(locations.map(\.name) == ["iCloud Drive", "Google Drive", "OneDrive"])
        #expect(locations.map(\.detail) == [nil, "a@b.c", "Personal"])
        #expect(locations[1].url.path == home.path + "/Library/CloudStorage/GoogleDrive-a@b.c")
    }

    @Test func noCloudFoldersMeansNoCloudLocations() throws {
        try folder("home")
        #expect(cloudLocations(home: home).isEmpty)
    }

    @Test func volumesExcludeTheBootVolume() {
        let volumes = mountedVolumes()
        #expect(volumes.allSatisfy { $0.url.path.hasPrefix("/Volumes/") && $0.accessibilityID == "sidebar.volume.\($0.name)" })
    }
}

final class FavoritesTests {
    let suite = "properfinder.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }

    let a = URL(fileURLWithPath: "/tmp/a", isDirectory: true)
    let b = URL(fileURLWithPath: "/tmp/b", isDirectory: true)
    let c = URL(fileURLWithPath: "/tmp/c", isDirectory: true)

    @Test func startsEmptyAndPersistsAdds() {
        let store = FavoritesStore(defaults: defaults)
        #expect(store.urls.isEmpty)

        store.add(a)
        store.add(URL(fileURLWithPath: "/tmp/b/"))
        store.add(URL(fileURLWithPath: "/tmp/a/"))

        #expect(FavoritesStore(defaults: defaults).urls.map(\.path) == ["/tmp/a", "/tmp/b"])
        #expect(defaults.stringArray(forKey: "favorites") == ["/tmp/a", "/tmp/b"])
        #expect(store.locations.map(\.accessibilityID) == ["sidebar.favorite.a", "sidebar.favorite.b"])
    }

    @Test func removePersists() {
        let store = FavoritesStore(defaults: defaults)
        [a, b, c].forEach(store.add)

        store.remove(b)

        #expect(FavoritesStore(defaults: defaults).urls.map(\.path) == ["/tmp/a", "/tmp/c"])
        #expect(!store.contains(b))
        #expect(store.contains(a))
    }

    @Test(arguments: [
        (IndexSet([0]), 3, ["/tmp/b", "/tmp/c", "/tmp/a"]),
        (IndexSet([2]), 0, ["/tmp/c", "/tmp/a", "/tmp/b"]),
        (IndexSet([0]), 2, ["/tmp/b", "/tmp/a", "/tmp/c"]),
        (IndexSet([1]), 1, ["/tmp/a", "/tmp/b", "/tmp/c"]),
        (IndexSet([0, 2]), 1, ["/tmp/a", "/tmp/c", "/tmp/b"]),
    ])
    func movesLikeSwiftUIOnMove(source: IndexSet, destination: Int, expected: [String]) {
        let store = FavoritesStore(defaults: defaults)
        [a, b, c].forEach(store.add)

        store.move(fromOffsets: source, toOffset: destination)

        #expect(FavoritesStore(defaults: defaults).urls.map(\.path) == expected)
    }
}

final class DirectoryWatcherTests: TempDirectory {
    let queue = DispatchQueue(label: "watcher-tests")

    private func counter(debounce: TimeInterval = 0.1) -> (DirectoryWatcher, () -> Int) {
        let lock = NSLock()
        var count = 0
        let watcher = DirectoryWatcher(url: root, debounce: debounce, queue: queue) { lock.withLock { count += 1 } }!
        return (watcher, { lock.withLock { count } })
    }

    @Test func reportsAFileCreatedOnDisk() throws {
        let (watcher, count) = counter()
        try file("external.txt")
        Thread.sleep(forTimeInterval: 0.5)
        #expect(count() == 1)
        _ = watcher
    }

    @Test func reportsDeletionAndRename() throws {
        let url = try file("a.txt")
        let (watcher, count) = counter()

        try fm.moveItem(at: url, to: root.appendingPathComponent("b.txt"))
        Thread.sleep(forTimeInterval: 0.4)
        try fm.removeItem(at: root.appendingPathComponent("b.txt"))
        Thread.sleep(forTimeInterval: 0.4)

        #expect(count() == 2)
        _ = watcher
    }

    @Test func burstsAreDebouncedIntoOneCallback() throws {
        let (watcher, count) = counter(debounce: 0.3)
        for i in 0..<10 { try file("f\(i).txt") }
        Thread.sleep(forTimeInterval: 0.8)
        #expect(count() == 1)
        _ = watcher
    }

    @Test func quietFolderAndCancelledWatcherDoNotFire() throws {
        let (watcher, count) = counter()
        Thread.sleep(forTimeInterval: 0.3)
        #expect(count() == 0)

        watcher.cancel()
        try file("after-cancel.txt")
        Thread.sleep(forTimeInterval: 0.3)
        #expect(count() == 0)
    }

    @Test func unreadableFolderGivesNoWatcher() {
        #expect(DirectoryWatcher(url: root.appendingPathComponent("missing")) {} == nil)
    }
}
