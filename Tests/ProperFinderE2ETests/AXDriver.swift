import AppKit
import ApplicationServices

struct AXDriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class AXDriver {
    static let accessibilityHint = "This process is not trusted for Accessibility: grant Accessibility to your terminal (System Settings > Privacy & Security > Accessibility), then rerun"

    let app: NSRunningApplication
    let appElement: AXUIElement
    var timeout: TimeInterval = 5

    var pid: pid_t { app.processIdentifier }

    init(app: NSRunningApplication) {
        self.app = app
        appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 5)
    }

    static func launch(_ bundle: URL, arguments: [String], timeout: TimeInterval = 15) async throws -> AXDriver {
        guard AXIsProcessTrusted() else { throw AXDriverError(accessibilityHint) }
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw AXDriverError("No app bundle at \(bundle.path)") }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = arguments
        config.addsToRecentItems = false
        let app = try await NSWorkspace.shared.openApplication(at: bundle, configuration: config)
        let driver = AXDriver(app: app)
        do {
            let hint = "a window (if an argument is an existing path, AppKit opens it as a document instead of creating the initial window unless the app registers NSTreatUnknownArgumentsAsOpen=NO)"
            _ = try driver.waitFor(hint, timeout: timeout) { driver.window }
        } catch {
            driver.terminate()
            throw error
        }
        return driver
    }

    // NSRunningApplication.isTerminated only updates when the main run loop spins, which the test runner's
    // main thread may never do, so liveness is read from the kernel instead.
    var isRunning: Bool { kill(pid, 0) == 0 || errno != ESRCH }

    func terminate() {
        guard isRunning else { return }
        app.terminate()
        if !poll(5, { !self.isRunning }) {
            app.forceTerminate()
            poll(5) { !self.isRunning }
        }
    }

    func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
    func identifier(_ element: AXUIElement) -> String? { string(element, "AXIdentifier") }
    func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute) }
    func title(_ element: AXUIElement) -> String? { string(element, kAXTitleAttribute) }
    func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    func parent(_ element: AXUIElement) -> AXUIElement? { attribute(element, kAXParentAttribute).map { $0 as! AXUIElement } }

    func value(_ element: AXUIElement) -> String? {
        switch attribute(element, kAXValueAttribute) {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    // Lists and tables report AXSelected on the row, while the identifier usually sits on a cell inside it.
    func isSelected(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let node = current else { return false }
            if attribute(node, kAXSelectedAttribute) as? Bool == true { return true }
            current = parent(node)
        }
        return false
    }

    func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    var window: AXUIElement? {
        (attribute(appElement, kAXFocusedWindowAttribute) as! AXUIElement?)
            ?? (attribute(appElement, kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    // The menu bar is skipped: its closed menus still expose every item, so a title search would hit
    // "Edit > Copy" instead of the context menu that is actually open.
    func find(in root: AXUIElement? = nil, maxDepth: Int = 60, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [(root ?? appElement, 0)]
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            if matches(element) { return element }
            guard depth < maxDepth else { continue }
            for child in children(element) where role(child) != kAXMenuBarRole {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    func findAll(in root: AXUIElement? = nil, where matches: (AXUIElement) -> Bool) -> [AXUIElement] {
        var found: [AXUIElement] = []
        _ = find(in: root) { element in
            if matches(element) { found.append(element) }
            return false
        }
        return found
    }

    func exists(_ id: String) -> Bool { find { identifier($0) == id } != nil }

    func element(_ id: String, timeout: TimeInterval? = nil) throws -> AXUIElement {
        try waitFor("element with AXIdentifier \"\(id)\"", timeout: timeout) { find { identifier($0) == id } }
    }

    func element(role: String, title: String, timeout: TimeInterval? = nil) throws -> AXUIElement {
        try waitFor("\(role) titled \"\(title)\"", timeout: timeout) {
            find { self.role($0) == role && (self.title($0) == title || self.string($0, kAXDescriptionAttribute) == title) }
        }
    }

    func waitFor(_ what: String, timeout: TimeInterval? = nil, _ lookup: () -> AXUIElement?) throws -> AXUIElement {
        var found: AXUIElement?
        let seconds = timeout ?? self.timeout
        if poll(seconds, { found = lookup(); return found != nil }) { return found! }
        throw AXDriverError("\(what) not found within \(seconds)s in \(app.bundleIdentifier ?? "pid \(pid)").\n\(dump())")
    }

    func waitGone(_ id: String, timeout: TimeInterval? = nil) throws {
        let seconds = timeout ?? self.timeout
        if !poll(seconds, { !exists(id) }) {
            throw AXDriverError("element \"\(id)\" still present after \(seconds)s.\n\(dump())")
        }
    }

    func dump(_ root: AXUIElement? = nil, maxLines: Int = 400) -> String {
        var lines: [String] = []
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard lines.count < maxLines else { return }
            let fields = [
                identifier(element).map { "id=\($0)" },
                title(element).flatMap { $0.isEmpty ? nil : "title=\"\($0)\"" },
                string(element, kAXDescriptionAttribute).flatMap { $0.isEmpty ? nil : "desc=\"\($0)\"" },
                value(element).map { "value=\"\($0.prefix(80))\"" },
            ].compactMap { $0 }
            lines.append(String(repeating: "  ", count: depth) + (role(element) ?? "?") + " " + fields.joined(separator: " "))
            for child in children(element) where role(child) != kAXMenuBarRole { walk(child, depth + 1) }
        }
        walk(root ?? appElement, 0)
        if lines.count >= maxLines { lines.append("… (truncated)") }
        return "AX tree:\n" + lines.joined(separator: "\n")
    }

    func activate() {
        guard !app.isActive || !(attribute(appElement, kAXFrontmostAttribute) as? Bool ?? false) else { return }
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        poll(2) { self.attribute(self.appElement, kAXFrontmostAttribute) as? Bool ?? false }
    }

    func perform(_ action: String, on element: AXUIElement) throws {
        let result = AXUIElementPerformAction(element, action as CFString)
        guard result == .success else { throw AXDriverError("\(action) failed (\(result.rawValue)) on \(describe(element))") }
    }

    func press(_ element: AXUIElement) throws {
        if actions(element).contains(kAXPressAction) {
            try perform(kAXPressAction, on: element)
        } else {
            try click(element)
        }
    }

    func press(_ id: String) throws { try press(element(id)) }

    func click(_ element: AXUIElement, right: Bool = false, at point: CGPoint? = nil, count: Int = 1) throws {
        guard let target = point ?? frame(element).map({ CGPoint(x: $0.midX, y: $0.midY) }) else {
            throw AXDriverError("no frame to click on \(describe(element))")
        }
        click(at: target, right: right, count: count)
    }

    func click(at point: CGPoint, right: Bool = false, count: Int = 1) {
        activate()
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        for clickNumber in 1...count {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
                event?.post(tap: .cghidEventTap)
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
    }

    func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        activate()
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown)
            event?.flags = flags
            event?.postToPid(pid)
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    func type(_ text: String) {
        activate()
        for unit in text.utf16 {
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown)
                event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [unit])
                event?.postToPid(pid)
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    // Typing first, like a user: on an NSTextField that is being edited, AXValue only replaces the cell's value
    // while the field editor keeps the old text, and the next commit writes that old text back (measured).
    func setText(_ element: AXUIElement, _ text: String) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var all = CFRange(location: 0, length: (value(element) ?? "").utf16.count)
        if let range = AXValueCreate(.cfRange, &all) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, range)
        }
        type(text)
        if !poll(1, { value(element) == text }) {
            AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        }
    }

    func isFocused(_ element: AXUIElement) -> Bool { attribute(element, kAXFocusedAttribute) as? Bool == true }

    var focusedElement: AXUIElement? { attribute(appElement, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement } }

    // Return goes through the field editor when there is one, which AXConfirm bypasses.
    func confirm(_ element: AXUIElement) throws {
        if isFocused(element) || !actions(element).contains(kAXConfirmAction) {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            key(Key.returnKey)
        } else {
            try perform(kAXConfirmAction, on: element)
        }
    }

    func openMenuItem(_ title: String) -> AXUIElement? {
        for menu in findAll(where: { role($0) == kAXMenuRole }) {
            if let item = find(in: menu, where: { role($0) == kAXMenuItemRole && self.title($0) == title }) { return item }
        }
        return nil
    }

    func closeMenus() {
        if find(where: { role($0) == kAXMenuRole }) != nil { key(Key.escape) }
    }

    // AXShowMenu first because it needs no pointer; SwiftUI often answers it with no menu or the wrong one,
    // so a real right-click is the fallback.
    func pressContextMenuItem(_ title: String, on element: AXUIElement, at point: CGPoint? = nil) throws {
        if point == nil, actions(element).contains(kAXShowMenuAction) {
            AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
            if poll(1, { openMenuItem(title) != nil }), let item = openMenuItem(title) {
                return try perform(kAXPressAction, on: item)
            }
            closeMenus()
        }
        try click(element, right: true, at: point)
        do {
            let item = try waitFor("context menu item \"\(title)\"", timeout: 3) { openMenuItem(title) }
            try perform(kAXPressAction, on: item)
        } catch {
            closeMenus()
            throw error
        }
    }

    func describe(_ element: AXUIElement) -> String {
        "\(role(element) ?? "?") id=\(identifier(element) ?? "-") title=\(title(element) ?? "-")"
    }

    @discardableResult
    func poll(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    static var pasteboardString: String? { NSPasteboard.general.string(forType: .string) }

    static func setPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // Virtual key codes are physical ANSI positions: code 0 is "A" on QWERTY but "Q" on AZERTY (a ⌘ code-0
    // shortcut quit the app under test, measured). Only add letters that sit at the same place on common layouts.
    enum Key {
        static let l: CGKeyCode = 37
        static let returnKey: CGKeyCode = 36
        static let escape: CGKeyCode = 53
        static let delete: CGKeyCode = 51
    }
}
