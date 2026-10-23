import AppKit
import SwiftUI
import Testing
@testable import ProperFinderApp

@MainActor
final class HostedWindow {
    let browser: Browser
    let window: NSWindow

    init(viewMode: ViewMode = .list, prepare: (Browser) throws -> Void = { _ in }) throws {
        _ = NSApplication.shared
        // SwiftUI only builds its accessibility tree once an assistive client shows up; this is the flag such a client sets.
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        browser = try Browser()
        browser.model.viewMode = viewMode
        try prepare(browser)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: BrowserView(model: browser.model))
        window.makeKeyAndOrderFront(nil)
    }

    func settle(_ seconds: Double = 0.3) async {
        window.layoutIfNeeded()
        try? await Task.sleep(for: .seconds(seconds))
    }

    func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            if condition() { return true }
            await settle(0.05)
        }
        return condition()
    }

    // SwiftUI's element proxies implement the NSAccessibility methods without being castable to the protocol, so go through KVC.
    func elements() -> [NSObject] {
        var found: [NSObject] = []
        var queue: [NSObject] = [window]
        var seen = Set<ObjectIdentifier>()
        while !queue.isEmpty {
            let element = queue.removeFirst()
            guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
            found.append(element)
            let children = accessibility(element, "accessibilityChildren") ?? element.accessibilityAttributeValue(.children)
            queue += (children as? [NSObject]) ?? []
        }
        return found
    }

    func accessibility(_ element: NSObject, _ key: String) -> Any? {
        element.responds(to: NSSelectorFromString(key)) ? element.value(forKey: key) : nil
    }

    func identifier(of element: NSObject) -> String? {
        (accessibility(element, "accessibilityIdentifier") ?? element.accessibilityAttributeValue(.identifier)) as? String
    }

    func identifiers() -> Set<String> {
        Set(elements().compactMap(identifier(of:)).filter { !$0.isEmpty })
    }

    func element(_ identifier: String) async -> NSObject? {
        var found: NSObject?
        _ = await waitFor {
            found = elements().first { self.identifier(of: $0) == identifier }
            return found != nil
        }
        return found
    }

    func textField(_ identifier: String) async -> NSTextField? {
        let element = await element(identifier)
        return element as? NSTextField ?? (element as? NSCell)?.controlView as? NSTextField
    }

    // cacheDisplay skips the vibrant sidebar column, so it is drawn again on top from its own view.
    func snapshot(to file: URL) throws {
        let frame = window.contentView!.superview!
        let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
        frame.cacheDisplay(in: frame.bounds, to: rep)
        if let sidebar = elements().first(where: { identifier(of: $0) == "sidebar" }) as? NSView {
            let sidebarRep = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds)!
            sidebar.cacheDisplay(in: sidebar.bounds, to: sidebarRep)
            var rect = sidebar.convert(sidebar.bounds, to: frame)
            if frame.isFlipped { rect.origin.y = frame.bounds.height - rect.maxY }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            sidebarRep.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }
        try rep.representation(using: .png, properties: [:])!.write(to: file)
    }

    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
            NSApp.sendEvent(event)
        }
    }

    func fileListHasFocus() -> Bool {
        var responder = window.firstResponder as? NSView
        while let view = responder, !(view is NSTableView) { responder = view.superview }
        return responder != nil
    }

    func focusFileList() async -> Bool {
        guard let list = await element("fileList") as? NSView else { return false }
        return window.makeFirstResponder(list)
    }

    func close() { window.close() }
}

@MainActor @Suite(.serialized)
struct HostedViewTests {
    @Test func listViewExposesTheContractIdentifiers() async throws {
        let hosted = try HostedWindow()
        defer { hosted.close() }
        _ = await hosted.element("item.alpha.txt")
        let ids = hosted.identifiers()
        let expected = ["sidebar", "sidebar.home", "sidebar.documents", "sidebar.applications", "sidebar.trash",
                        "backButton", "forwardButton", "pathField", "viewModePicker", "hiddenFilesToggle", "searchField",
                        "fileList", "statusBar", "item.Home", "item.Other", "item.Sub", "item.alpha.txt", "item.beta.md"]
        #expect(Set(expected).subtracting(ids).isEmpty, "missing: \(Set(expected).subtracting(ids).sorted())")
        for absent in ["item..hidden", "fileGrid", "pathBar", "copyPathButton", "renameField"] {
            #expect(!ids.contains(absent), "\(absent) should not be there")
        }
        #expect(hosted.window.title == hosted.browser.dir.root.lastPathComponent)
    }

    @Test func iconViewExposesTheGridAndItsCells() async throws {
        let hosted = try HostedWindow(viewMode: .icons)
        defer { hosted.close() }
        #expect(await hosted.element("item.beta.md") != nil)
        let ids = hosted.identifiers()
        #expect(ids.isSuperset(of: ["fileGrid", "item.Sub", "item.alpha.txt"]))
        #expect(!ids.contains("fileList"))
    }

    @Test func pathFieldShowsTheFolderAndNavigatesOnReturn() async throws {
        let hosted = try HostedWindow()
        defer { hosted.close() }
        let root = hosted.browser.dir.root
        let field = try #require(await hosted.textField("pathField"))
        #expect(field.accessibilityValue() == root.path)

        field.stringValue = root.appendingPathComponent("Sub/inner.txt").path
        field.sendAction(field.action, to: field.target)
        #expect(hosted.browser.model.currentURL.path == root.appendingPathComponent("Sub").path)
        #expect(hosted.browser.selectedNames == ["inner.txt"])
        #expect(await hosted.waitFor { field.stringValue == root.appendingPathComponent("Sub").path })
        #expect(await hosted.element("item.inner.txt") != nil)
    }

    // Launch focus is covered by E2E: a hosted window already starts with the table focused.
    @Test func fileListGetsFocusBackWhenThePathFieldIsDone() async throws {
        let hosted = try HostedWindow()
        defer { hosted.close() }
        let field = try #require(await hosted.textField("pathField"))
        hosted.window.makeFirstResponder(field)
        #expect(!hosted.fileListHasFocus())
        field.stringValue = hosted.browser.url("Sub/inner.txt").path
        field.sendAction(field.action, to: field.target)
        #expect(await hosted.waitFor { hosted.fileListHasFocus() })

        hosted.window.makeFirstResponder(field)
        field.currentEditor()?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(await hosted.waitFor { hosted.fileListHasFocus() })
    }

    @Test func invalidPathTurnsTheFieldRedAndStays() async throws {
        let hosted = try HostedWindow()
        defer { hosted.close() }
        let field = try #require(await hosted.textField("pathField"))
        let missing = hosted.browser.dir.root.appendingPathComponent("missing").path
        field.stringValue = missing
        field.sendAction(field.action, to: field.target)
        #expect(hosted.browser.model.currentURL.path == hosted.browser.dir.root.path)
        #expect(await hosted.waitFor { field.textColor == .systemRed })
        #expect(field.stringValue == missing)
    }

    @Test func editPathCommandFocusesTheFieldWithEverythingSelected() async throws {
        let hosted = try HostedWindow()
        defer { hosted.close() }
        let field = try #require(await hosted.textField("pathField"))
        hosted.browser.model.focusContent()
        #expect(await hosted.waitFor { field.currentEditor() == nil })
        hosted.browser.model.beginPathEditing()
        #expect(await hosted.waitFor { field.currentEditor() != nil })
        #expect(field.currentEditor()?.selectedRange == NSRange(location: 0, length: hosted.browser.dir.root.path.utf16.count))
    }

    @Test func invalidPathTypedWhileEditingStaysInTheField() async throws {
        let hosted = try HostedWindow()
        defer { hosted.close() }
        let field = try #require(await hosted.textField("pathField"))
        hosted.window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor())
        editor.replaceCharacters(in: NSRange(location: 0, length: editor.string.utf16.count), with: "/no/such/folder")
        field.sendAction(field.action, to: field.target)
        #expect(hosted.browser.model.pathInvalid)
        #expect(field.stringValue == "/no/such/folder")
        #expect(field.currentEditor() != nil)
        #expect(await hosted.waitFor { field.textColor == .systemRed })
        #expect(field.currentEditor()?.selectedRange == NSRange(location: "/no/such/folder".utf16.count, length: 0))

        field.currentEditor()?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(field.stringValue == hosted.browser.dir.root.path)
        #expect(!hosted.browser.model.pathInvalid)
    }

    @Test func backButtonPressGoesBack() async throws {
        let hosted = try HostedWindow()
        defer { hosted.close() }
        hosted.browser.model.open([hosted.browser.url("Other")])
        let back = try #require(await hosted.element("backButton"))
        #expect(await hosted.waitFor { hosted.accessibility(back, "isAccessibilityEnabled") as? Bool == true })
        back.accessibilityPerformAction(.press)
        #expect(await hosted.waitFor { hosted.browser.model.currentURL.path == hosted.browser.dir.root.path })
    }

    @Test func newFolderShowsTheRenameFieldAndCommitsOnEndEditing() async throws {
        let hosted = try HostedWindow()
        defer { hosted.close() }
        _ = await hosted.element("item.alpha.txt")
        hosted.browser.model.newFolder()
        let field = try #require(await hosted.textField("renameField"))
        #expect(await hosted.waitFor { field.currentEditor() != nil })
        #expect(field.currentEditor()?.selectedRange == NSRange(location: 0, length: "untitled folder".utf16.count))

        field.currentEditor()?.replaceCharacters(in: NSRange(location: 0, length: field.stringValue.utf16.count), with: "Renamed")
        hosted.window.makeFirstResponder(nil)
        #expect(await hosted.waitFor { hosted.browser.dir.exists("Renamed") })
        #expect(!hosted.browser.dir.exists("untitled folder"))
    }

    @Test func rejectedNameKeepsTheRenameFieldWithTheTypedText() async throws {
        let hosted = try HostedWindow()
        defer { hosted.close() }
        _ = await hosted.element("item.alpha.txt")
        hosted.browser.model.beginRename(hosted.browser.url("alpha.txt"))
        let field = try #require(await hosted.textField("renameField"))
        #expect(await hosted.waitFor { field.currentEditor() != nil })
        field.currentEditor()?.replaceCharacters(in: NSRange(location: 0, length: field.stringValue.utf16.count), with: "beta.md")
        hosted.window.makeFirstResponder(nil)
        #expect(hosted.browser.model.errorMessage != nil)
        hosted.browser.model.errorMessage = nil

        #expect(await hosted.waitFor { field.currentEditor() != nil })
        #expect(field.stringValue == "beta.md")
        #expect(field.currentEditor()?.selectedRange == NSRange(location: 0, length: 4))
        #expect(hosted.browser.dir.contents("alpha.txt") == "alpha")
    }

    @Test func renameFieldSelectsTheBaseNameOnly() async throws {
        let hosted = try HostedWindow()
        defer { hosted.close() }
        _ = await hosted.element("item.alpha.txt")
        hosted.browser.model.beginRename(hosted.browser.url("alpha.txt"))
        let field = try #require(await hosted.textField("renameField"))
        #expect(await hosted.waitFor { field.currentEditor() != nil })
        #expect(field.currentEditor()?.selectedRange == NSRange(location: 0, length: 5))
    }

    @Test func returnOnTheSelectedRowStartsRename() async throws {
        let hosted = try HostedWindow()
        defer { hosted.close() }
        #expect(await hosted.focusFileList())
        hosted.browser.model.selection = [hosted.browser.url("alpha.txt")]
        await hosted.settle(0.1)
        hosted.press("\r", keyCode: 36)
        #expect(await hosted.waitFor { hosted.browser.model.renamingURL?.lastPathComponent == "alpha.txt" })
    }

    @Test func spaceTogglesQuickLook() async throws {
        let hosted = try HostedWindow()
        defer { hosted.close() }
        #expect(await hosted.focusFileList())
        hosted.browser.model.selection = [hosted.browser.url("alpha.txt")]
        await hosted.settle(0.1)
        hosted.press(" ", keyCode: 49)
        #expect(await hosted.waitFor { hosted.browser.model.quickLookURL?.lastPathComponent == "alpha.txt" })
        hosted.browser.model.quickLookURL = nil
    }

    @Test func addedFavoriteAppearsInTheSidebar() async throws {
        let hosted = try HostedWindow()
        defer { hosted.close() }
        hosted.browser.places.addFavorite(hosted.browser.url("Other"))
        #expect(await hosted.element("sidebar.favorite.Other") != nil)
    }

    @Test func unreadableTrashShowsTheFullDiskAccessState() async throws {
        let hosted = try HostedWindow { browser in
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: browser.places.trash.url.path)
        }
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hosted.browser.places.trash.url.path)
            hosted.close()
        }
        hosted.browser.model.navigate(to: hosted.browser.places.trash.url)
        #expect(hosted.browser.model.listingError != nil)
        #expect(await hosted.waitFor {
            hosted.elements().contains { hosted.accessibility($0, "accessibilityLabel") as? String == "Open Privacy Settings" }
        })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROPERFINDER_SNAPSHOT_DIR"] != nil, "Set PROPERFINDER_SNAPSHOT_DIR to render PNGs"))
    func snapshots() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROPERFINDER_SNAPSHOT_DIR"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let list = try HostedWindow { $0.places.addFavorite($0.url("Other")) }
        list.browser.model.selection = [list.browser.url("alpha.txt")]
        _ = await list.element("item.alpha.txt")
        try list.snapshot(to: dir.appendingPathComponent("list.png"))

        list.browser.model.viewMode = .icons
        _ = await list.element("fileGrid")
        await list.settle()
        try list.snapshot(to: dir.appendingPathComponent("icons.png"))

        list.browser.model.viewMode = .list
        _ = await list.element("fileList")
        let field = try #require(await list.textField("pathField"))
        list.window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor())
        editor.replaceCharacters(in: NSRange(location: 0, length: editor.string.utf16.count), with: "/no/such/folder")
        field.sendAction(field.action, to: field.target)
        #expect(list.browser.model.pathInvalid)
        await list.settle()
        try list.snapshot(to: dir.appendingPathComponent("path-invalid.png"))

        list.browser.model.cancelPathEditing()
        list.browser.model.newFile()
        _ = await list.element("renameField")
        await list.settle()
        try list.snapshot(to: dir.appendingPathComponent("rename.png"))
        list.close()

        let trash = try HostedWindow { browser in
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: browser.places.trash.url.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trash.browser.places.trash.url.path) }
        trash.browser.model.navigate(to: trash.browser.places.trash.url)
        await trash.settle(0.5)
        try trash.snapshot(to: dir.appendingPathComponent("trash-no-access.png"))
        trash.close()
    }
}
