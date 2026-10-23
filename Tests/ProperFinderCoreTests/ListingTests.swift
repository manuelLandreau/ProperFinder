import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ProperFinderCore

final class ListingTests: TempDirectory {
    @Test func hidesDotFilesUnlessAsked() throws {
        try file("visible.txt")
        try file(".hidden")
        try folder(".git")

        #expect(try listDirectory(root, showHidden: false).map(\.name) == ["visible.txt"])
        #expect(try listDirectory(root, showHidden: true).map(\.name).sorted() == [".git", ".hidden", "visible.txt"])
    }

    @Test func hidesItemsFlaggedHidden() throws {
        var url = try file("flagged.txt")
        var values = URLResourceValues()
        values.isHidden = true
        try url.setResourceValues(values)

        #expect(try listDirectory(root, showHidden: false).isEmpty)
        #expect(try listDirectory(root, showHidden: true).map(\.name) == ["flagged.txt"])
    }

    @Test func foldersComeFirstThenNaturalNameOrder() throws {
        for name in ["file10.txt", "file2.txt", "Banana.txt", "apple.txt"] { try file(name) }
        for name in ["zeta", "Alpha"] { try folder(name) }

        #expect(try listDirectory(root, showHidden: false).map(\.name) == ["Alpha", "zeta", "apple.txt", "Banana.txt", "file2.txt", "file10.txt"])
        #expect(try listDirectory(root, showHidden: false, ascending: false).map(\.name) == ["zeta", "Alpha", "file10.txt", "file2.txt", "Banana.txt", "apple.txt"])
    }

    @Test func sortsByDateAndSize() throws {
        try file("old.txt", "123456", modified: Date(timeIntervalSince1970: 1_000))
        try file("new.txt", "1", modified: Date(timeIntervalSince1970: 3_000))
        try file("mid.txt", "123", modified: Date(timeIntervalSince1970: 2_000))
        try folder("dir")

        #expect(try listDirectory(root, showHidden: false, sortedBy: .dateModified).map(\.name) == ["dir", "old.txt", "mid.txt", "new.txt"])
        #expect(try listDirectory(root, showHidden: false, sortedBy: .dateModified, ascending: false).map(\.name) == ["dir", "new.txt", "mid.txt", "old.txt"])
        #expect(try listDirectory(root, showHidden: false, sortedBy: .size).map(\.name) == ["dir", "new.txt", "mid.txt", "old.txt"])
        #expect(try listDirectory(root, showHidden: false, sortedBy: .size, ascending: false).map(\.name) == ["dir", "old.txt", "mid.txt", "new.txt"])
    }

    @Test func sortsByKindWithNameAsTieBreak() throws {
        for name in ["b.txt", "a.png", "a.txt"] { try file(name) }
        let names = try listDirectory(root, showHidden: false, sortedBy: .kind).map(\.name)
        let pngFirst = UTType("public.png")!.localizedDescription!.localizedStandardCompare(UTType("public.plain-text")!.localizedDescription!) == .orderedAscending
        #expect(names == (pngFirst ? ["a.png", "a.txt", "b.txt"] : ["a.txt", "b.txt", "a.png"]))
    }

    @Test func describesItems() throws {
        try file("note.txt", "hello")
        try folder("Sub")
        try folder("Tool.app/Contents")
        let items = Dictionary(uniqueKeysWithValues: try listDirectory(root, showHidden: false).map { ($0.name, $0) })

        #expect(items["note.txt"]?.size == 5)
        #expect(items["note.txt"]?.isFolder == false)
        #expect(items["note.txt"]?.kind.lowercased() == UTType("public.plain-text")?.localizedDescription?.lowercased())
        #expect(items["note.txt"]?.kind.first?.isUppercase == true)
        #expect(items["Sub"]?.kind.first?.isUppercase == true)
        #expect(items["Sub"]?.isFolder == true)
        #expect(items["Sub"]?.size == nil)
        #expect(items["Tool.app"]?.isFolder == false)
    }

    @Test func symlinkToFolderIsAFolder() throws {
        let target = try folder("target")
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)
        try fm.createSymbolicLink(at: root.appendingPathComponent("broken"), withDestinationURL: root.appendingPathComponent("nowhere"))
        let items = Dictionary(uniqueKeysWithValues: try listDirectory(root, showHidden: false).map { ($0.name, $0) })

        #expect(items["link"]?.isFolder == true)
        #expect(items["broken"]?.isFolder == false)
    }

    @Test func itemURLsMatchTheURLsReturnedByCreation() throws {
        #expect(root.path.hasPrefix("/var/"))
        let folder = try createFolder(in: root)
        let file = try createFile(in: root)
        #expect(Set(try listDirectory(root, showHidden: false).map(\.url)) == [folder, file])
    }

    @Test func listsUnicodeAndSpacedNames() throws {
        try file("café crème.txt")
        try file("日本語 ファイル.md")
        #expect(try Set(listDirectory(root, showHidden: false).map(\.name)) == ["café crème.txt", "日本語 ファイル.md"])
    }

    @Test func listingAMissingFolderThrows() {
        #expect(throws: (any Error).self) { try listDirectory(self.root.appendingPathComponent("missing"), showHidden: false) }
    }

    @Test func searchIgnoresCaseAndDiacritics() throws {
        for name in ["Café.txt", "cafeteria.md", "tea.txt"] { try file(name) }
        let items = try listDirectory(root, showHidden: false)

        #expect(filterItems(items, matching: "CAFE").map(\.name) == ["Café.txt", "cafeteria.md"])
        #expect(filterItems(items, matching: "café").map(\.name) == ["Café.txt", "cafeteria.md"])
        #expect(filterItems(items, matching: "  ").count == 3)
        #expect(filterItems(items, matching: "xyz").isEmpty)
    }

    @Test func reportsAvailableCapacity() {
        #expect((availableCapacity(at: root) ?? 0) > 0)
    }
}
