import AppKit
import SwiftUI

struct BrowserCommands: Commands {
    @FocusedValue(\.browser) private var model: BrowserModel?

    /// Edit shortcuts (⌘C, ⌘V, ⌘⌫…) are menu key equivalents, which win over the focused text field: hand them back to it.
    private func editingText(_ action: Selector) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSText else { return false }
        NSApp.sendAction(action, to: nil, from: nil)
        return true
    }

    private func go(_ path: String) {
        guard let model else { return }
        model.navigate(to: model.places.home.appendingPathComponent(path, isDirectory: true))
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { model?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New File") { model?.newFile() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Open") { model.map { $0.open($0.selectedURLs) } }
                .keyboardShortcut("o")
                .disabled(model?.selection.isEmpty ?? true)
            Button("Quick Look") { model?.toggleQuickLook() }
                .keyboardShortcut("y")
                .disabled(model?.selection.isEmpty ?? true)
            Button("Rename") { model.map { $0.selectedURLs.first.map($0.beginRename) } }
                .disabled(model?.selection.count != 1)
            Divider()
            Button("Move to Trash") {
                if !editingText(#selector(NSResponder.deleteToBeginningOfLine(_:))) { model.map { $0.trash($0.selectedURLs) } }
            }
            .keyboardShortcut(.delete)
            Button("Empty Trash…") { model?.confirmingEmptyTrash = true }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(model == nil)
            Divider()
            Button("Add to Favorites") {
                guard let model else { return }
                let folders = model.selectedURLs.filter { model.item(at: $0)?.isFolder == true }
                (folders.isEmpty ? [model.currentURL] : folders).forEach(model.places.addFavorite)
            }
            .keyboardShortcut("t", modifiers: [.command, .control])
            .disabled(model == nil)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { _ = editingText(#selector(NSText.cut(_:))) }
                .keyboardShortcut("x")
            Button("Copy") {
                if !editingText(#selector(NSText.copy(_:))) { model.map { $0.copyToPasteboard($0.selectedURLs) } }
            }
            .keyboardShortcut("c")
            Button("Paste") {
                if !editingText(#selector(NSText.paste(_:))) { model?.paste() }
            }
            .keyboardShortcut("v")
            Button("Move Here") { model?.paste(move: true) }
                .keyboardShortcut("v", modifiers: [.command, .option])
            Button("Copy Path") {
                guard let model else { return }
                model.copyPaths(model.selection.isEmpty ? [model.currentURL] : model.selectedURLs)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Select All") {
                if !editingText(#selector(NSText.selectAll(_:))) { model?.selectAll() }
            }
            .keyboardShortcut("a")
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { model?.focusSearch() }
                .keyboardShortcut("f")
        }
        CommandGroup(before: .toolbar) {
            Button("as List") { model?.viewMode = .list }
                .keyboardShortcut("1")
            Button("as Icons") { model?.viewMode = .icons }
                .keyboardShortcut("2")
            Divider()
            Button { model?.showHidden.toggle() } label: {
                model?.showHidden == true ? Text("Hide Hidden Files") : Text("Show Hidden Files")
            }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[")
                .disabled(model?.backStack.isEmpty ?? true)
            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]")
                .disabled(model?.forwardStack.isEmpty ?? true)
            Button("Enclosing Folder") { model?.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(!(model?.canGoUp ?? false))
            // A menu key equivalent: NSTableView swallows ⌘↓ before any SwiftUI key handler sees it.
            Button("Open Selection") { model.map { $0.open($0.selectedURLs) } }
                .keyboardShortcut(.downArrow)
                .disabled(model?.selection.isEmpty ?? true)
            Divider()
            Button("Home") { go("") }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Desktop") { go("Desktop") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Documents") { go("Documents") }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Downloads") { go("Downloads") }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Applications") { model?.navigate(to: URL(fileURLWithPath: "/Applications", isDirectory: true)) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("Go to Folder…") { model?.beginPathEditing() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Edit Path") { model?.beginPathEditing() }
                .keyboardShortcut("l")
        }
    }
}
