import AppKit
import ApplicationServices
import Foundation
import Testing

private let e2eEnabled = ProcessInfo.processInfo.environment["PROPERFINDER_E2E"] == "1"

// The app trashes it into the user's real Trash (the test can't list ~/.Trash without Full Disk Access): a recognizable name.
private let victim = "properfinder-e2e-trash-me-\(UUID().uuidString).txt"

private let appBundle = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROPERFINDER_APP"]
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ProperFinder.app").path)

@Suite(.serialized, .enabled(if: e2eEnabled, "Black-box UI tests: run scripts/test-e2e.sh (sets PROPERFINDER_E2E=1)"))
struct E2ETests {
    @Test func accessibilityIsGranted() throws {
        try #require(AXIsProcessTrusted(), Comment(rawValue: AXDriver.accessibilityHint))
    }

    @Test func opensOnRootAndListsFixture() async throws {
        try await withApp { app, root in
            for name in ["alpha.txt", "beta.md", victim, "Sub", "Other"] {
                _ = try app.element("item.\(name)")
            }
            #expect(!app.exists("item..hidden"))
            #expect(!app.exists("item.inner.txt"))
            let titles = { (app.attribute(app.appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []).compactMap(app.title) }
            #expect(app.poll(3) { titles() == [root.lastPathComponent] }, "window titles: \(titles())")
            #expect(app.poll(3) { app.focusedElement.flatMap(app.identifier) == "fileList" },
                    "the file list should have keyboard focus, not \(app.focusedElement.map(app.describe) ?? "nothing")")
        }
    }

    @Test func pathFieldShowsCurrentFolderAndNavigates() async throws {
        try await withApp { app, root in
            #expect(samePath(app.value(try app.element("pathField")), root))

            let other = root.appendingPathComponent("Other")
            try commitPath(app, other.path)
            _ = try app.element("item.other-file.txt")
            try app.waitGone("item.alpha.txt")
            #expect(app.poll(3) { samePath(pathValue(app), other) })
            #expect(app.poll(3) { app.focusedElement.flatMap(app.identifier) == "fileList" },
                    "Return should hand focus back to the file list, not \(app.focusedElement.map(app.describe) ?? "nothing")")
        }
    }

    @Test func pathFieldFilePathSelectsItInParent() async throws {
        try await withApp { app, root in
            try commitPath(app, root.appendingPathComponent("Sub/inner.txt").path)
            let row = try app.element("item.inner.txt")
            #expect(app.poll(3) { samePath(pathValue(app), root.appendingPathComponent("Sub")) })
            #expect(app.poll(3) { app.isSelected(row) }, "inner.txt should be selected.\n\(app.dump())")
        }
    }

    @Test func pathFieldRejectsInvalidPathAndEscapeRestores() async throws {
        try await withApp { app, root in
            let missing = "/properfinder-e2e-missing-\(UUID().uuidString)"
            try commitPath(app, missing)
            Thread.sleep(forTimeInterval: 0.5)
            let field = try app.element("pathField")
            #expect(app.value(field) == missing, "an invalid path must stay in the field for correction, got \(app.value(field) ?? "nil")")
            #expect(app.exists("item.alpha.txt"))

            app.key(AXDriver.Key.escape)
            #expect(app.poll(3) { samePath(app.value(field), root) }, "Escape should restore the current folder path")
        }
    }

    @Test func backgroundMenuCopyPathCopiesCurrentFolder() async throws {
        try await withApp { app, root in
            let copied = try copiedString(by: app) {
                try app.pressContextMenuItem("Copy Path", on: app.element("fileList"), at: backgroundPoint(app))
            }
            #expect(samePath(copied, root), "pasteboard: \(copied ?? "unchanged")")
        }
    }

    @Test func backgroundMenuNewFolderCreatesItAndStartsRename() async throws {
        try await withApp { app, root in
            let folder = root.appendingPathComponent("untitled folder")
            #expect(!exists(folder))
            try app.pressContextMenuItem("New Folder", on: app.element("fileList"), at: backgroundPoint(app))
            #expect(app.poll(3) { exists(folder, directory: true) })
            _ = try app.element("renameField")
        }
    }

    @Test func backgroundMenuNewFileCreatesUntitledTxt() async throws {
        try await withApp { app, root in
            let file = root.appendingPathComponent("untitled.txt")
            #expect(!exists(file))
            try app.pressContextMenuItem("New File", on: app.element("fileList"), at: backgroundPoint(app))
            #expect(app.poll(3) { exists(file, directory: false) })
            _ = try app.element("renameField")
        }
    }

    @Test func inlineRenameRenamesOnDisk() async throws {
        try await withApp { app, root in
            let old = root.appendingPathComponent("alpha.txt"), new = root.appendingPathComponent("gamma.txt")
            #expect(!exists(new))
            try app.pressContextMenuItem("Rename", on: app.element("item.alpha.txt"))
            let field = try app.element("renameField")
            app.setText(field, "gamma.txt")
            try app.confirm(field)
            #expect(app.poll(3) { exists(new) && !exists(old) })
            _ = try app.element("item.gamma.txt")
        }
    }

    @Test func itemMenuMoveToTrashRemovesItFromFolder() async throws {
        try await withApp { app, root in
            let file = root.appendingPathComponent(victim)
            try app.pressContextMenuItem("Move to Trash", on: app.element("item.\(victim)"))
            #expect(app.poll(3) { !exists(file) })
            #expect(exists(root.appendingPathComponent("alpha.txt")))
            try app.waitGone("item.\(victim)")
        }
    }

    @Test func commandDeleteEditsThePathFieldInsteadOfTrashing() async throws {
        try await withApp { app, root in
            let file = root.appendingPathComponent(victim)
            let row = try app.element("item.\(victim)")
            try app.click(row)
            #expect(app.poll(3) { app.isSelected(row) })

            app.key(AXDriver.Key.l, .maskCommand)
            let field = try app.element("pathField")
            #expect(app.poll(3) { app.isFocused(field) })
            app.key(AXDriver.Key.delete, .maskCommand)
            #expect(app.poll(3) { app.value(field)?.isEmpty ?? true }, "⌘⌫ should clear the field, got \(app.value(field) ?? "nil")")
            Thread.sleep(forTimeInterval: 0.5)
            #expect(exists(file))

            try app.click(row)
            app.key(AXDriver.Key.delete, .maskCommand)
            #expect(app.poll(3) { !exists(file) }, "with the list focused, ⌘⌫ should trash the selection")
        }
    }

    @Test func itemMenuCopyPathCopiesItemPath() async throws {
        try await withApp { app, root in
            let copied = try copiedString(by: app) {
                try app.pressContextMenuItem("Copy Path", on: app.element("item.alpha.txt"))
            }
            #expect(samePath(copied, root.appendingPathComponent("alpha.txt")), "pasteboard: \(copied ?? "unchanged")")
        }
    }

    @Test(arguments: [false, true]) func rightClickSelectsTheClickedItem(iconView: Bool) async throws {
        try await withApp { app, root in
            if iconView {
                let segments = app.children(try app.element("viewModePicker"))
                try app.press(try #require(segments.last))
                _ = try app.element("fileGrid")
            }
            let alpha = try app.element("item.alpha.txt"), beta = try app.element("item.beta.md")
            try app.click(alpha)
            #expect(app.poll(3) { app.isSelected(alpha) })

            let center = try #require(app.frame(beta).map { CGPoint(x: $0.midX, y: $0.midY) })
            let copied = try copiedString(by: app) { try app.pressContextMenuItem("Copy Path", on: beta, at: center) }
            #expect(samePath(copied, root.appendingPathComponent("beta.md")), "pasteboard: \(copied ?? "unchanged")")
            #expect(app.poll(3) { app.isSelected(beta) && !app.isSelected(alpha) })
        }
    }

    @Test func backAndForwardAfterEnteringSubfolder() async throws {
        try await withApp { app, _ in
            #expect(app.attribute(try app.element("backButton"), kAXEnabledAttribute) as? Bool == false)
            try app.pressContextMenuItem("Open", on: app.element("item.Sub"))
            _ = try app.element("item.inner.txt")
            try app.waitGone("item.alpha.txt")

            try app.press("backButton")
            _ = try app.element("item.alpha.txt")
            try app.waitGone("item.inner.txt")

            try app.press("forwardButton")
            _ = try app.element("item.inner.txt")
            try app.waitGone("item.alpha.txt")
        }
    }

    @Test func hiddenFilesToggleShowsDotfile() async throws {
        try await withApp { app, _ in
            #expect(!app.exists("item..hidden"))
            try app.press("hiddenFilesToggle")
            _ = try app.element("item..hidden")
            try app.press("hiddenFilesToggle")
            try app.waitGone("item..hidden")
        }
    }

    @Test func sidebarHomeNavigatesHome() async throws {
        try await withApp { app, root in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let field = try app.element("pathField")
            #expect(samePath(app.value(field), root))

            try app.press("sidebar.home")
            #expect(app.poll(5) { samePath(app.value(field), home) }, "pathField: \(app.value(field) ?? "nil")")
            try app.waitGone("item.alpha.txt")
            #expect(app.window.flatMap(app.title) == home.lastPathComponent)
        }
    }
}

private func withApp(_ body: (AXDriver, URL) throws -> Void) async throws {
    try #require(AXIsProcessTrusted(), Comment(rawValue: AXDriver.accessibilityHint))
    let root = try makeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try await AXDriver.launch(appBundle, arguments: ["--ui-testing", "--root", root.path, "-AppleLanguages", "(en)"])
    defer { app.terminate() }
    _ = try app.element("item.alpha.txt", timeout: 10)
    try body(app, root)
}

private func makeFixture() throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ProperFinderE2E-\(UUID().uuidString)")
    for dir in ["Sub", "Other"] {
        try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    for file in ["alpha.txt", "beta.md", victim, ".hidden", "Sub/inner.txt", "Other/other-file.txt"] {
        try Data(file.utf8).write(to: root.appendingPathComponent(file))
    }
    return root.resolvingSymlinksInPath()
}

// ⌘L first: it is the shortcut a user would take, and it guarantees the field has keyboard focus for the Return fallback.
private func commitPath(_ app: AXDriver, _ text: String) throws {
    app.key(AXDriver.Key.l, .maskCommand)
    let field = try app.element("pathField")
    app.setText(field, text)
    try app.confirm(field)
}

private func pathValue(_ app: AXDriver) -> String? {
    app.find { app.identifier($0) == "pathField" }.flatMap(app.value)
}

private func exists(_ url: URL, directory: Bool? = nil) -> Bool {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
    return directory.map { $0 == isDir.boolValue } ?? true
}

// The app may legitimately show /var/... or /private/var/... for the same temp folder.
private func samePath(_ text: String?, _ url: URL) -> Bool {
    guard let text, text.hasPrefix("/") else { return false }
    return URL(fileURLWithPath: text).resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
}

private func copiedString(by app: AXDriver, _ action: () throws -> Void) throws -> String? {
    let sentinel = "properfinder-e2e-\(UUID().uuidString)"
    AXDriver.setPasteboard(sentinel)
    try action()
    app.poll(3) { AXDriver.pasteboardString != sentinel }
    let copied = AXDriver.pasteboardString
    return copied == sentinel ? nil : copied
}

// A Table's empty background belongs to its scroll view; right-clicking near the bottom avoids the rows of a small fixture.
private func backgroundPoint(_ app: AXDriver) throws -> CGPoint {
    let list = try app.element("fileList")
    let area = app.parent(list).flatMap { app.role($0) == kAXScrollAreaRole ? $0 : nil } ?? list
    let frame = try #require(app.frame(area))
    return CGPoint(x: frame.minX + 40, y: frame.maxY - 15)
}
