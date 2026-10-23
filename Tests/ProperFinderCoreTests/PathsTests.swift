import Foundation
import Testing
@testable import ProperFinderCore

final class PathsTests: TempDirectory {
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }

    @Test func expandsTildeAndTrims() throws {
        try folder("home/Documents")

        #expect(try resolvePathInput("  ~  \n", home: home).folder.path == home.path)
        #expect(try resolvePathInput("~/Documents", home: home) == PathTarget(folder: URL(fileURLWithPath: home.path + "/Documents", isDirectory: true), selection: nil))
    }

    @Test func acceptsTrailingSlashAndDotDot() throws {
        try folder("a/b")
        #expect(try resolvePathInput(root.path + "/a/b/").folder.path == root.path + "/a/b")
        #expect(try resolvePathInput(root.path + "/a/b/../").folder.path == root.path + "/a")
    }

    @Test func pathWithSpacesAndUnicode() throws {
        try folder("Mes documents/été")
        #expect(try resolvePathInput(root.path + "/Mes documents/été").folder.path == root.path + "/Mes documents/été")
    }

    @Test func filePathOpensTheParentAndSelectsTheFile() throws {
        let url = try file("dir/report.pdf")
        let target = try resolvePathInput(url.path)
        #expect(target.folder.path == root.path + "/dir")
        #expect(target.selection?.path == url.path)
    }

    @Test func packageIsSelectedNotEntered() throws {
        try folder("Apps/Tool.app/Contents")
        let target = try resolvePathInput(root.path + "/Apps/Tool.app")
        #expect(target.folder.path == root.path + "/Apps")
        #expect(target.selection?.lastPathComponent == "Tool.app")
    }

    @Test func rejectsRelativeAndEmptyPaths() {
        #expect(throws: FinderError.relativePath("Documents")) { try resolvePathInput("Documents", home: self.home) }
        #expect(throws: FinderError.relativePath("~user/x")) { try resolvePathInput("~user/x", home: self.home) }
        #expect(throws: FinderError.relativePath("")) { try resolvePathInput("   ", home: self.home) }
    }

    @Test func rejectsMissingPaths() {
        let missing = root.path + "/nope"
        #expect(throws: FinderError.notFound(missing)) { try resolvePathInput(missing) }
        #expect(throws: FinderError.notFound("~/nope")) { try resolvePathInput("~/nope", home: self.home) }
    }
}
