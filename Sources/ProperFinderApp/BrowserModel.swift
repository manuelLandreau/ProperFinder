import AppKit
import Observation
import ProperFinderCore

enum ViewMode {
    case list, icons
}

@MainActor @Observable
final class BrowserModel {
    let places: Places
    @ObservationIgnored let pasteboard: NSPasteboard
    @ObservationIgnored let fileManager: FileManager
    @ObservationIgnored private var watcher: DirectoryWatcher?

    private(set) var currentURL: URL
    private(set) var items: [FileItem] = []
    private(set) var listingError: Error?
    private(set) var availableSpace: Int64?
    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []
    var selection: Set<URL> = []
    @ObservationIgnored var hoveredURL: URL?
    var showHidden = false { didSet { reload() } }
    var sortKey = SortKey.name { didSet { items = sortItems(items, by: sortKey, ascending: ascending) } }
    var ascending = true { didSet { items = sortItems(items, by: sortKey, ascending: ascending) } }
    var viewMode = ViewMode.list
    var searchText = ""
    var searchFocusRequest = 0
    var pathText = ""
    var pathInvalid = false
    private(set) var pathFocusRequest = 0
    private(set) var contentFocusRequest = 0
    private(set) var renamingURL: URL?
    var errorMessage: String?
    var confirmingEmptyTrash = false
    var quickLookURL: URL?

    init(places: Places, start: URL, pasteboard: NSPasteboard = .general, fileManager: FileManager = .default) {
        self.places = places
        self.pasteboard = pasteboard
        self.fileManager = fileManager
        currentURL = start
        show(start, selecting: [])
    }

    var visibleItems: [FileItem] { filterItems(items, matching: searchText) }
    var selectedURLs: [URL] { visibleItems.map(\.url).filter(selection.contains) }
    var title: String { fileManager.displayName(atPath: currentURL.path) }
    var isTrash: Bool { currentURL.path == places.trash.url.path }

    func item(at url: URL) -> FileItem? {
        items.first { $0.url.path == url.path }
    }

    func isRenaming(_ item: FileItem) -> Bool {
        renamingURL?.path == item.url.path
    }

    func navigate(to url: URL, selecting selected: URL? = nil) {
        if url.path != currentURL.path {
            backStack.append(currentURL)
            forwardStack.removeAll()
            show(url, selecting: [selected].compactMap { $0 })
        } else {
            cancelPathEditing()
            select([selected].compactMap { $0 })
        }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentURL)
        show(previous, selecting: [])
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        show(next, selecting: [])
    }

    var canGoUp: Bool { currentURL.path != "/" }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: currentURL.deletingLastPathComponent(), selecting: currentURL)
    }

    // NSWorkspace would open folders in Apple's Finder: browse the first one here instead.
    func open(_ urls: [URL]) {
        let folders = urls.filter { item(at: $0)?.isFolder == true }
        for url in urls where !folders.contains(url) { NSWorkspace.shared.open(url) }
        if let folder = folders.first { navigate(to: folder) }
    }

    func open(_ urls: [URL], with app: URL) {
        Task {
            do {
                try await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openInTerminal() {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        open([currentURL], with: terminal)
    }

    private func show(_ url: URL, selecting selected: [URL]) {
        currentURL = URL(fileURLWithPath: url.path, isDirectory: true)
        searchText = ""
        pathText = currentURL.path
        pathInvalid = false
        renamingURL = nil
        quickLookURL = nil
        selection = []
        watch()
        reload()
        select(selected)
        focusContent()
    }

    // The watcher holds the folder's vnode, which goes silent once the folder is deleted and recreated (or renamed) at
    // the same path: re-arming on every event follows whatever now sits there.
    private func watch() {
        watcher = DirectoryWatcher(url: currentURL) { [weak self] in
            MainActor.assumeIsolated {
                self?.watch()
                self?.reload()
            }
        }
    }

    func reload() {
        do {
            items = try listDirectory(currentURL, showHidden: showHidden, sortedBy: sortKey, ascending: ascending, fileManager: fileManager)
            listingError = nil
        } catch {
            items = []
            listingError = error
        }
        let paths = Set(items.map(\.url.path))
        selection = selection.filter { paths.contains($0.path) }
        availableSpace = availableCapacity(at: currentURL)
    }

    /// Operations return URLs built differently from the listing (trailing slash, symlinked roots): match them by path.
    private func select(_ urls: [URL]) {
        let paths = Set(urls.map(\.path))
        selection = Set(items.filter { paths.contains($0.url.path) }.map(\.url))
    }

    func beginPathEditing() {
        pathFocusRequest += 1
    }

    func cancelPathEditing() {
        pathText = currentURL.path
        pathInvalid = false
    }

    func commitPathEditing() {
        do {
            let target = try resolvePathInput(pathText, home: places.home, fileManager: fileManager)
            navigate(to: target.folder, selecting: target.selection)
            pathInvalid = false
            focusContent()
        } catch {
            NSSound.beep()
            pathInvalid = true
        }
    }

    func copyPaths(_ urls: [URL]) {
        writeString(urls.map(\.path).joined(separator: "\n"))
    }

    private func writeString(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func newFolder() {
        createAndRename { try createFolder(in: currentURL, fileManager: fileManager) }
    }

    func newFile() {
        createAndRename { try createFile(in: currentURL, fileManager: fileManager) }
    }

    private func createAndRename(_ create: () throws -> URL) {
        do {
            let url = try create()
            searchText = ""
            reload()
            select([url])
            renamingURL = selectedURLs.first
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginRename(_ url: URL) {
        guard let item = item(at: url) else { return }
        selection = [item.url]
        renamingURL = item.url
    }

    func commitRename(_ newName: String) {
        guard let url = renamingURL else { return }
        perform {
            let renamed = try renameItem(at: url, to: newName, fileManager: fileManager)
            renamingURL = nil
            return [renamed]
        }
    }

    func cancelRename() {
        renamingURL = nil
    }

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        perform {
            try trashItems(urls, fileManager: fileManager)
            return []
        }
    }

    func copyToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    private var fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] { [.urlReadingFileURLsOnly: true] }

    var canPaste: Bool { pasteboard.canReadObject(forClasses: [NSURL.self], options: fileURLOptions) }

    func paste(move: Bool = false) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLOptions) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        perform {
            move ? try moveItems(urls, to: currentURL, fileManager: fileManager) : try copyItems(urls, to: currentURL, fileManager: fileManager)
        }
    }

    func drop(_ urls: [URL], into folder: URL) {
        let urls = urls.filter { $0.path != folder.path }
        guard !urls.isEmpty else { return }
        if folder.path == places.trash.url.path {
            trash(urls)
            return
        }
        perform { try dropItems(urls, into: folder, fileManager: fileManager) }
    }

    func emptyTrash() {
        do {
            try ProperFinderCore.emptyTrash(at: places.trash.url, fileManager: fileManager)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    private func perform(_ operation: () throws -> [URL]) {
        do {
            let urls = try operation()
            reload()
            select(urls)
        } catch {
            reload()
            errorMessage = error.localizedDescription
        }
    }

    func toggleQuickLook() {
        quickLookURL = quickLookURL == nil ? selectedURLs.first : nil
    }

    func selectAll() {
        selection = Set(visibleItems.map(\.url))
    }

    func focusSearch() {
        searchFocusRequest += 1
    }

    func focusContent() {
        contentFocusRequest += 1
    }

    var statusText: String {
        let items = itemCount(visibleItems.count)
        guard let availableSpace else { return items }
        let space = ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file)
        return String(localized: "\(items), \(space) available")
    }
}

@MainActor @Observable
final class Places {
    let home: URL
    let standard: [SidebarLocation]
    let trash: SidebarLocation
    private(set) var cloud: [SidebarLocation]
    private(set) var volumes: [SidebarLocation] = []
    private(set) var favorites: [SidebarLocation]
    @ObservationIgnored private let store: FavoritesStore
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults, fileManager: FileManager = .default) {
        self.home = home
        standard = standardLocations(home: home, fileManager: fileManager)
        trash = trashLocation(home: home)
        cloud = cloudLocations(home: home, fileManager: fileManager)
        store = FavoritesStore(defaults: defaults)
        favorites = store.locations
        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            }
        }
    }

    func refreshVolumes() {
        volumes = mountedVolumes()
    }

    func eject(_ volume: SidebarLocation) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
        refreshVolumes()
    }

    func isFavorite(_ url: URL) -> Bool { store.contains(url) }

    func addFavorite(_ url: URL) {
        store.add(url)
        favorites = store.locations
    }

    func removeFavorite(_ url: URL) {
        store.remove(url)
        favorites = store.locations
    }

    func moveFavorites(fromOffsets source: IndexSet, toOffset destination: Int) {
        store.move(fromOffsets: source, toOffset: destination)
        favorites = store.locations
    }

    var all: [SidebarLocation] { standard + favorites + cloud + volumes + [trash] }

    func url(named id: String) -> URL? {
        all.first { $0.accessibilityID == id }?.url
    }
}

func itemCount(_ count: Int) -> String {
    count == 1 ? String(localized: "1 item") : String(localized: "\(count) items")
}
