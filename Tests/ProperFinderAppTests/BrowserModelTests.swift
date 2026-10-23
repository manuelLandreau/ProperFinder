import AppKit
import Foundation
import Testing
@testable import ProperFinderApp
@testable import ProperFinderCore

// FileManager.trashItem has no destination parameter: without this, tests would fill the user's real Trash.
final class FixtureTrashFileManager: FileManager {
    let trash: URL

    init(trash: URL) {
        self.trash = trash
        super.init()
    }

    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        let destination = trash.appendingPathComponent(url.lastPathComponent)
        try moveItem(at: url, to: destination)
        outResultingURL?.pointee = destination as NSURL
    }
}

@MainActor
final class Browser {
    let dir: TempDirectory
    let home: URL
    let defaultsSuite = "properfinder.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("properfinder.tests.\(UUID().uuidString)"))
    let places: Places
    let model: BrowserModel

    init() throws {
        dir = try TempDirectory()
        try dir.file("alpha.txt", "alpha")
        try dir.file("beta.md", "beta")
        try dir.file(".hidden", "secret")
        try dir.file("Sub/inner.txt", "inner")
        try dir.folder("Other")
        home = try dir.folder("Home")
        try dir.folder("Home/Documents")
        try dir.folder("Home/.Trash")
        defaults = UserDefaults(suiteName: defaultsSuite)!
        places = Places(home: home, defaults: defaults)
        model = BrowserModel(places: places, start: dir.root, pasteboard: pasteboard,
                             fileManager: FixtureTrashFileManager(trash: places.trash.url))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        pasteboard.releaseGlobally()
    }

    func url(_ path: String) -> URL { dir.root.appendingPathComponent(path) }
    var names: [String] { model.visibleItems.map(\.name) }
    var selectedNames: [String] { model.selectedURLs.map(\.lastPathComponent) }
    var pasteboardString: String? { pasteboard.string(forType: .string) }
}

@MainActor
struct NavigationTests {
    @Test func listsTheStartFolderFoldersFirstWithoutHiddenFiles() throws {
        let b = try Browser()
        #expect(b.names == ["Home", "Other", "Sub", "alpha.txt", "beta.md"])
        #expect(b.model.title == b.dir.root.lastPathComponent)
        #expect(b.model.pathText == b.dir.root.path)
        #expect(b.model.statusText.hasPrefix("5 items"))
    }

    @Test func backForwardAndUp() throws {
        let b = try Browser()
        #expect(b.model.backStack.isEmpty)
        b.model.open([b.url("Sub")])
        #expect(b.names == ["inner.txt"])
        #expect(b.model.pathText == b.url("Sub").path)
        #expect(b.model.contentFocusRequest > 0)

        b.model.goBack()
        #expect(b.model.currentURL.path == b.dir.root.path)
        #expect(b.model.forwardStack.count == 1)

        b.model.goForward()
        #expect(b.model.currentURL.path == b.url("Sub").path)

        b.model.goUp()
        #expect(b.model.currentURL.path == b.dir.root.path)
        #expect(b.selectedNames == ["Sub"])
        #expect(b.model.forwardStack.isEmpty)
    }

    @Test func openingSeveralFoldersBrowsesTheFirstOneHere() throws {
        let b = try Browser()
        b.model.open([b.url("Sub"), b.url("Other")])
        #expect(b.model.currentURL.path == b.url("Sub").path)
    }

    @Test func pathFieldNavigatesToAFolder() throws {
        let b = try Browser()
        b.model.pathText = "  \(b.url("Other").path)  "
        b.model.commitPathEditing()
        #expect(b.model.currentURL.path == b.url("Other").path)
        #expect(b.model.pathText == b.url("Other").path)
        #expect(!b.model.pathInvalid)
    }

    @Test func pathFieldWithAFilePathOpensItsParentAndSelectsIt() throws {
        let b = try Browser()
        b.model.pathText = b.url("Sub/inner.txt").path
        b.model.commitPathEditing()
        #expect(b.model.currentURL.path == b.url("Sub").path)
        #expect(b.selectedNames == ["inner.txt"])
    }

    @Test func pathFieldExpandsTilde() throws {
        let b = try Browser()
        b.model.pathText = "~/Documents"
        b.model.commitPathEditing()
        #expect(b.model.currentURL.path == b.home.appendingPathComponent("Documents").path)
    }

    @Test func invalidPathKeepsTheTextAndTheFolder() throws {
        let b = try Browser()
        for text in [b.url("missing").path, "relative/path"] {
            b.model.pathText = text
            b.model.commitPathEditing()
            #expect(b.model.pathInvalid)
            #expect(b.model.pathText == text)
            #expect(b.model.currentURL.path == b.dir.root.path)
            #expect(b.model.backStack.isEmpty)
        }
        b.model.pathText = b.url("missing").path + "x"
        b.model.cancelPathEditing()
        #expect(b.model.pathText == b.dir.root.path)
        #expect(!b.model.pathInvalid)
    }

    @Test func sidebarSelectionNavigates() throws {
        let b = try Browser()
        let sidebar = Sidebar(model: b.model)
        #expect(sidebar.selection.wrappedValue == nil)
        sidebar.selection.wrappedValue = "sidebar.documents"
        #expect(b.model.currentURL.path == b.home.appendingPathComponent("Documents").path)
        #expect(sidebar.selection.wrappedValue == "sidebar.documents")
        sidebar.selection.wrappedValue = "sidebar.home"
        #expect(b.model.currentURL.path == b.home.path)
    }

    @Test func searchFiltersCaseAndDiacriticInsensitive() throws {
        let b = try Browser()
        try b.dir.file("Été.txt")
        b.model.reload()
        b.model.searchText = "ete"
        #expect(b.names == ["Été.txt"])
        b.model.searchText = "ALPHA"
        #expect(b.names == ["alpha.txt"])
        b.model.open([b.url("Sub")])
        #expect(b.model.searchText.isEmpty)
    }

    @Test func hiddenFilesToggle() throws {
        let b = try Browser()
        #expect(!b.names.contains(".hidden"))
        b.model.showHidden = true
        #expect(b.names.contains(".hidden"))
        b.model.showHidden = false
        #expect(!b.names.contains(".hidden"))
    }

    @Test func sortingKeepsFoldersFirst() throws {
        let b = try Browser()
        try b.dir.file("big.bin", String(repeating: "x", count: 5000))
        b.model.reload()
        b.model.sortKey = .size
        b.model.ascending = false
        #expect(b.names.prefix(3).sorted() == ["Home", "Other", "Sub"])
        #expect(b.names[3] == "big.bin")
    }

    @Test func unreadableFolderShowsAnErrorInsteadOfItems() throws {
        let b = try Browser()
        let locked = try b.dir.folder("Locked")
        try b.dir.file("Locked/x.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        b.model.navigate(to: locked)
        #expect(b.model.listingError != nil)
        #expect(b.model.items.isEmpty)
    }

    @Test func launchOptions() {
        let options = LaunchOptions(["ProperFinder", "--ui-testing", "--root", "/tmp/x", "-AppleLanguages", "(en)"])
        #expect(options.uiTesting)
        #expect(options.root?.path == "/tmp/x")
        #expect(LaunchOptions(["ProperFinder"]).root == nil)
        #expect(!LaunchOptions(["ProperFinder", "--root"]).uiTesting)
    }
}

@MainActor
struct FileOperationTests {
    @Test func copyPathOfCurrentFolderAndOfSeveralItems() throws {
        let b = try Browser()
        b.model.copyPaths([b.model.currentURL])
        #expect(b.pasteboardString == b.dir.root.path)
        b.model.copyPaths([b.url("alpha.txt"), b.url("beta.md")])
        #expect(b.pasteboardString == b.url("alpha.txt").path + "\n" + b.url("beta.md").path)
    }

    @Test func newFolderIsCreatedSelectedAndRenamedInline() throws {
        let b = try Browser()
        b.model.newFolder()
        #expect(b.dir.exists("untitled folder"))
        #expect(b.selectedNames == ["untitled folder"])
        #expect(b.model.renamingURL?.lastPathComponent == "untitled folder")

        b.model.commitRename("Projects")
        #expect(b.dir.exists("Projects") && !b.dir.exists("untitled folder"))
        #expect(b.selectedNames == ["Projects"])
        #expect(b.model.renamingURL == nil)

        b.model.newFolder()
        b.model.cancelRename()
        b.model.newFolder()
        #expect(b.dir.exists("untitled folder 2"))
    }

    @Test func newFileCreatesUntitledTxt() throws {
        let b = try Browser()
        b.model.newFile()
        #expect(b.dir.contents("untitled.txt") == "")
        #expect(b.model.renamingURL?.lastPathComponent == "untitled.txt")
    }

    @Test func renameCollisionShowsAnErrorAndKeepsBothFiles() throws {
        let b = try Browser()
        b.model.beginRename(b.url("alpha.txt"))
        b.model.commitRename("beta.md")
        #expect(b.model.errorMessage != nil)
        #expect(b.dir.contents("alpha.txt") == "alpha")
        #expect(b.dir.contents("beta.md") == "beta")
        #expect(b.model.renamingURL?.lastPathComponent == "alpha.txt")

        b.model.commitRename("gamma.txt")
        #expect(b.dir.contents("gamma.txt") == "alpha")
        #expect(b.model.renamingURL == nil)
    }

    @Test func emptyFileSizeReadsInBytes() throws {
        let b = try Browser()
        b.model.newFile()
        let bytes = ByteCountFormatter()
        bytes.allowedUnits = .useBytes
        #expect(b.model.item(at: b.url("untitled.txt"))?.sizeText == bytes.string(fromByteCount: 0))
    }

    @Test func trashMovesItemsToTheTrash() throws {
        let b = try Browser()
        b.model.trash([b.url("alpha.txt")])
        #expect(!b.dir.exists("alpha.txt"))
        #expect(b.dir.contents("Home/.Trash/alpha.txt") == "alpha")
        #expect(!b.names.contains("alpha.txt"))
        #expect(b.model.errorMessage == nil)
    }

    @Test func copyThenPasteKeepsBoth() throws {
        let b = try Browser()
        b.model.selection = [b.url("alpha.txt")]
        b.model.copyToPasteboard(b.model.selectedURLs)
        #expect(b.model.canPaste)

        b.model.open([b.url("Other")])
        b.model.paste()
        #expect(b.dir.contents("Other/alpha.txt") == "alpha")
        #expect(b.dir.exists("alpha.txt"))
        #expect(b.selectedNames == ["alpha.txt"])

        b.model.paste()
        #expect(b.dir.names(in: "Other") == ["alpha 2.txt", "alpha.txt"])
    }

    @Test func moveHereMovesTheFiles() throws {
        let b = try Browser()
        b.model.copyToPasteboard([b.url("alpha.txt"), b.url("beta.md")])
        b.model.open([b.url("Other")])
        b.model.paste(move: true)
        #expect(b.dir.names(in: "Other") == ["alpha.txt", "beta.md"])
        #expect(!b.dir.exists("alpha.txt") && !b.dir.exists("beta.md"))
    }

    @Test func pasteIsDisabledWithoutFileURLs() throws {
        let b = try Browser()
        b.model.copyPaths([b.url("alpha.txt")])
        #expect(!b.model.canPaste)
        b.model.paste()
        #expect(b.dir.names() == ["Home", "Other", "Sub", "alpha.txt", "beta.md", ".hidden"].sorted())
    }

    @Test func dropOntoAFolderMovesOnTheSameVolume() throws {
        let b = try Browser()
        b.model.drop([b.url("alpha.txt"), b.url("Other")], into: b.url("Other"))
        #expect(b.dir.names(in: "Other") == ["alpha.txt"])
        #expect(!b.dir.exists("alpha.txt"))
        #expect(b.dir.exists("Other"))
    }

    @Test func movingAFolderIntoItselfIsReported() throws {
        let b = try Browser()
        b.model.drop([b.dir.root], into: b.url("Sub"))
        #expect(b.model.errorMessage != nil)
        #expect(b.dir.exists("Sub/inner.txt"))
    }

    @Test func emptyTrashErasesTheTrashFolder() throws {
        let b = try Browser()
        try b.dir.file("Home/.Trash/old.txt")
        try b.dir.file("Home/.Trash/Old Folder/x.txt")
        b.model.navigate(to: b.places.trash.url)
        #expect(b.model.isTrash)
        #expect(b.names == ["Old Folder", "old.txt"])
        b.model.emptyTrash()
        #expect(b.dir.names(in: "Home/.Trash").isEmpty)
        #expect(b.names.isEmpty)
    }

    @Test func externalChangesRefreshTheListing() async throws {
        let b = try Browser()
        try b.dir.file("from-outside.txt")
        for _ in 0..<40 where !b.names.contains("from-outside.txt") {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(b.names.contains("from-outside.txt"))

        try FileManager.default.removeItem(at: b.url("alpha.txt"))
        for _ in 0..<40 where b.names.contains("alpha.txt") {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!b.names.contains("alpha.txt"))
    }

    @Test func listingFollowsAFolderRecreatedAtTheSamePath() async throws {
        let b = try Browser()
        b.model.open([b.url("Sub")])
        try FileManager.default.removeItem(at: b.url("Sub"))
        try b.dir.folder("Sub")
        for _ in 0..<40 where !b.names.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(b.names.isEmpty)

        try b.dir.file("Sub/new.txt")
        for _ in 0..<40 where b.names.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(b.names == ["new.txt"])
    }
}

@MainActor
struct FavoritesTests {
    @Test func addRemoveAndPersist() throws {
        let b = try Browser()
        b.places.addFavorite(b.url("Other"))
        b.places.addFavorite(b.url("Sub"))
        b.places.addFavorite(b.url("Other"))
        #expect(b.places.favorites.map(\.accessibilityID) == ["sidebar.favorite.Other", "sidebar.favorite.Sub"])
        #expect(FavoritesStore(defaults: b.defaults).urls.map(\.lastPathComponent) == ["Other", "Sub"])

        b.places.moveFavorites(fromOffsets: [1], toOffset: 0)
        #expect(b.places.favorites.map(\.name) == ["Sub", "Other"])

        Sidebar(model: b.model).selection.wrappedValue = "sidebar.favorite.Sub"
        #expect(b.model.currentURL.path == b.url("Sub").path)

        b.places.removeFavorite(b.url("Sub"))
        #expect(b.places.favorites.map(\.name) == ["Other"])
        #expect(FavoritesStore(defaults: b.defaults).urls.map(\.lastPathComponent) == ["Other"])
    }

    @Test func sidebarListsStandardPlacesAndTrash() throws {
        let b = try Browser()
        #expect(b.places.standard.map(\.accessibilityID).contains("sidebar.documents"))
        #expect(!b.places.standard.map(\.accessibilityID).contains("sidebar.desktop"))
        #expect(b.places.trash.url.path == b.home.appendingPathComponent(".Trash").path)
    }
}

struct LocalizationTests {
    @Test func everyUIStringHasAFrenchTranslation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let translated = try #require(NSDictionary(contentsOf: root.appendingPathComponent("Resources/fr.lproj/Localizable.strings")) as? [String: String])
        #expect(translated["New Folder"] == "Nouveau dossier")

        let call = try Regex(#"(?:Text|Button|Label|Section|Toggle|Menu|CommandMenu|TableColumn|Picker|ContentUnavailableView|\.help|\.alert|String\(localized:)\(\s*(?:localized:\s*)?"((?:[^"\\]|\\.)*)""#)
        var missing: [String] = []
        for folder in ["Sources/ProperFinderApp", "Sources/ProperFinderCore"] {
            for file in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path) {
                let source = try String(contentsOf: root.appendingPathComponent(folder).appendingPathComponent(file), encoding: .utf8)
                for match in source.matches(of: call) {
                    let key = String(match.output[1].substring ?? "")
                        .replacing(try Regex(#"\\\(count\)"#), with: "%lld")
                        .replacing(try Regex(#"\\\([^)]*\)"#), with: "%@")
                    if translated[key] == nil { missing.append(key) }
                }
            }
        }
        #expect(missing.isEmpty, "no French translation for: \(missing)")
    }
}
