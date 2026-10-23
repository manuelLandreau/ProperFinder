import Foundation
import Testing
@testable import ProperFinderCore

final class FileOperationsTests: TempDirectory {
    @Test func uniqueNamesNumberFromTwoBeforeTheExtension() throws {
        #expect(uniqueName(for: "untitled folder", in: root) == "untitled folder")
        try folder("untitled folder")
        #expect(uniqueName(for: "untitled folder", in: root) == "untitled folder 2")
        try folder("untitled folder 2")
        #expect(uniqueName(for: "untitled folder", in: root) == "untitled folder 3")

        try file("untitled.txt")
        #expect(uniqueName(for: "untitled.txt", in: root) == "untitled 2.txt")
        try file(".env")
        #expect(uniqueName(for: ".env", in: root) == ".env 2")
    }

    @Test func brokenSymlinkStillTakesItsName() throws {
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("nowhere"))
        #expect(uniqueName(for: "link", in: root) == "link 2")
    }

    @Test func createsFoldersAndFilesWithUniqueNames() throws {
        let first = try createFolder(in: root)
        let second = try createFolder(in: root)
        let file1 = try createFile(in: root)
        let file2 = try createFile(in: root)

        #expect([first, second, file1, file2].map(\.lastPathComponent) == ["untitled folder", "untitled folder 2", "untitled.txt", "untitled 2.txt"])
        #expect(names() == ["untitled 2.txt", "untitled folder", "untitled folder 2", "untitled.txt"])
        var isDirectory: ObjCBool = false
        #expect(fm.fileExists(atPath: second.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(contents("untitled.txt") == "")
    }

    @Test func createFileNeverOverwrites() throws {
        try file("untitled.txt", "keep me")
        _ = try createFile(in: root)
        #expect(contents("untitled.txt") == "keep me")
        #expect(contents("untitled 2.txt") == "")
    }

    @Test func renamesOnDisk() throws {
        let url = try file("a.txt", "data")
        let renamed = try renameItem(at: url, to: "été 2024 – notes.txt")

        #expect(renamed.lastPathComponent == "été 2024 – notes.txt")
        #expect(names() == ["été 2024 – notes.txt"])
        #expect(contents("été 2024 – notes.txt") == "data")
    }

    @Test func renamingToTheSameNameIsANoOp() throws {
        let url = try file("a.txt")
        #expect(try renameItem(at: url, to: "a.txt") == url)
        #expect(names() == ["a.txt"])
    }

    @Test func caseOnlyRenameWorks() throws {
        let url = try file("readme.md", "x")
        try renameItem(at: url, to: "README.md")
        #expect(names() == ["README.md"])
        #expect(contents("README.md") == "x")
    }

    @Test(arguments: [
        ("", FinderError.emptyName),
        ("   ", FinderError.emptyName),
        ("a/b", FinderError.invalidName("a/b")),
        ("a:b", FinderError.invalidName("a:b")),
        (".", FinderError.invalidName(".")),
        ("..", FinderError.invalidName("..")),
    ])
    func rejectsInvalidNames(name: String, error: FinderError) throws {
        let url = try file("a.txt")
        #expect(throws: error) { try renameItem(at: url, to: name) }
        #expect(names() == ["a.txt"])
    }

    @Test func refusesToRenameOntoAnExistingItem() throws {
        let url = try file("a.txt", "a")
        try file("b.txt", "b")
        #expect(throws: FinderError.nameTaken("b.txt")) { try renameItem(at: url, to: "b.txt") }
        #expect(contents("a.txt") == "a")
        #expect(contents("b.txt") == "b")
    }

    @Test func copyKeepsBothOnCollision() throws {
        let source = try file("src/report.pdf", "new")
        let dest = try folder("dest")
        try file("dest/report.pdf", "old")

        let copied = try copyItems([source], to: dest)

        #expect(copied.map(\.lastPathComponent) == ["report 2.pdf"])
        #expect(contents("dest/report.pdf") == "old")
        #expect(contents("dest/report 2.pdf") == "new")
        #expect(contents("src/report.pdf") == "new")
    }

    @Test func copyIntoTheSameFolderDuplicates() throws {
        let source = try file("a.txt", "x")
        _ = try copyItems([source], to: root)
        #expect(names() == ["a 2.txt", "a.txt"])
    }

    @Test func copiesFoldersRecursively() throws {
        let source = try folder("My Folder")
        try file("My Folder/inner/deep.txt", "deep")
        let dest = try folder("dest")

        _ = try copyItems([source], to: dest)

        #expect(contents("dest/My Folder/inner/deep.txt") == "deep")
        #expect(exists("My Folder/inner/deep.txt"))
    }

    @Test func moveKeepsBothOnCollision() throws {
        let source = try file("src/a.txt", "new")
        let dest = try folder("dest")
        try file("dest/a.txt", "old")

        let moved = try moveItems([source], to: dest)

        #expect(moved.map(\.lastPathComponent) == ["a 2.txt"])
        #expect(contents("dest/a.txt") == "old")
        #expect(contents("dest/a 2.txt") == "new")
        #expect(!exists("src/a.txt"))
    }

    @Test func movingIntoTheCurrentFolderChangesNothing() throws {
        let source = try file("a.txt")
        #expect(try moveItems([source], to: root) == [source])
        #expect(names() == ["a.txt"])
    }

    @Test func refusesMovingAFolderIntoItselfOrADescendant() throws {
        let parent = try folder("parent")
        let child = try folder("parent/child")
        try file("parent/keep.txt")

        #expect(throws: FinderError.moveIntoItself("parent")) { try moveItems([parent], to: parent) }
        #expect(throws: FinderError.moveIntoItself("parent")) { try moveItems([parent], to: child) }
        #expect(throws: FinderError.moveIntoItself("parent")) { try copyItems([parent], to: child) }
        #expect(throws: FinderError.moveIntoItself("parent")) { try dropItems([parent], into: child) }
        #expect(names(in: "parent") == ["child", "keep.txt"])
        #expect(names(in: "parent/child").isEmpty)
    }

    @Test func siblingWithSharedPrefixIsNotADescendant() throws {
        let source = try folder("photos")
        let target = try folder("photos-backup")
        _ = try moveItems([source], to: target)
        #expect(exists("photos-backup/photos"))
    }

    @Test func multiItemMoveIsRefusedBeforeAnythingMoves() throws {
        let loose = try file("loose.txt")
        let parent = try folder("parent")
        let child = try folder("parent/child")

        #expect(throws: FinderError.moveIntoItself("parent")) { try moveItems([loose, parent], to: child) }
        #expect(exists("loose.txt"))
    }

    @Test func dropOnTheSameVolumeMoves() throws {
        let source = try file("a.txt", "x")
        let dest = try folder("dest")
        #expect(isSameVolume(source, dest))

        _ = try dropItems([source], into: dest)

        #expect(!exists("a.txt"))
        #expect(contents("dest/a.txt") == "x")
    }

    @Test func dropOntoASymlinkToAnotherVolumeCopies() throws {
        let volume = try folder("volume")
        let image = root.appendingPathComponent("volume.dmg").path
        try hdiutil(["create", "-size", "2m", "-fs", "HFS+", "-volname", "PFTest", image])
        try hdiutil(["attach", "-nobrowse", "-noverify", "-mountpoint", volume.path, image])
        defer { try? hdiutil(["detach", "-force", volume.path]) }
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: volume)
        let source = try file("Report.txt", "keep me")

        _ = try dropItems([source], into: link)

        #expect(contents("Report.txt") == "keep me")
        #expect(contents("volume/Report.txt") == "keep me")
    }

    private func hdiutil(_ arguments: [String]) throws {
        let process = try Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: arguments + ["-quiet"])
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    @Test func differentVolumesAreDetected() throws {
        #expect(!isSameVolume(root, URL(fileURLWithPath: "/dev")))
        #expect(!isSameVolume(root, root.appendingPathComponent("missing")))
    }

    @Test func trashMovesTheItemOutOfTheFolder() throws {
        let url = try file("to trash.txt", "bye")
        try file("stay.txt")

        let trashed = try trashItems([url])
        defer { try? fm.removeItem(at: trashed[0]) }

        #expect(names() == ["stay.txt"])
        #expect(trashed[0] != url)
        #expect(fm.fileExists(atPath: trashed[0].path))
    }

    @Test func emptyTrashRemovesEverythingInside() throws {
        let trash = try folder("FakeTrash")
        try file("FakeTrash/a.txt")
        try file("FakeTrash/.hidden")
        try file("FakeTrash/dir/b.txt")

        try emptyTrash(at: trash)

        #expect(names(in: "FakeTrash").isEmpty)
        #expect(exists("FakeTrash"))
    }

    @Test func errorsHaveReadableDescriptions() {
        #expect(FinderError.nameTaken("b.txt").localizedDescription == "The name “b.txt” is already taken. Please choose a different name.")
        #expect(FinderError.notFound("/nope").localizedDescription == "The folder “/nope” can't be found.")
    }
}
