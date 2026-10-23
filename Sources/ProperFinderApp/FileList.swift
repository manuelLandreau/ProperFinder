import AppKit
import ProperFinderCore
import SwiftUI

extension FileItem {
    var sortDate: Date { dateModified ?? .distantPast }
    var sortSize: Int64 { size ?? -1 }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    var sizeText: String {
        guard let size else { return "--" }
        guard size == 0 else { return ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
        // Any unit set but bytes-only (.useAll included) renders an empty file as "Zero KB"; Finder says "Zero bytes".
        let bytes = ByteCountFormatter()
        bytes.allowedUnits = .useBytes
        return bytes.string(fromByteCount: 0)
    }
    var dateText: String { dateModified?.formatted(date: .abbreviated, time: .shortened) ?? "--" }
}

struct FileContent: View {
    @Bindable var model: BrowserModel
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if model.listingError != nil, model.isTrash {
                ContentUnavailableView {
                    Label("Full Disk Access Required", systemImage: "lock")
                } description: {
                    Text("macOS only lets apps with Full Disk Access list the Trash. Allow ProperFinder in System Settings › Privacy & Security › Full Disk Access, then reopen the Trash.")
                } actions: {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
            } else if let error = model.listingError {
                ContentUnavailableView("Can't Open This Folder", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            } else if model.viewMode == .list {
                FileTable(model: model).focused($focused)
            } else {
                FileGrid(model: model).focused($focused)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.contentFocusRequest) { focused = true }
        .dropDestination(for: URL.self) { urls, _ in
            model.drop(urls, into: model.currentURL)
            return true
        }
        .onKeyPress(keys: [.return, .space]) { press in
            handleKey(press)
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard model.renamingURL == nil else { return .ignored }
        switch press.key {
        case .return where press.modifiers.isEmpty:
            guard model.selectedURLs.count == 1 else { return .ignored }
            model.beginRename(model.selectedURLs[0])
        case .space where press.modifiers.isEmpty:
            model.toggleQuickLook()
        default:
            return .ignored
        }
        return .handled
    }
}

struct FileTable: View {
    @Bindable var model: BrowserModel

    private func comparator(_ key: SortKey, _ order: SortOrder) -> KeyPathComparator<FileItem> {
        switch key {
        case .name: KeyPathComparator(\.name, order: order)
        case .dateModified: KeyPathComparator(\.sortDate, order: order)
        case .size: KeyPathComparator(\.sortSize, order: order)
        case .kind: KeyPathComparator(\.kind, order: order)
        }
    }

    private var sortOrder: Binding<[KeyPathComparator<FileItem>]> {
        Binding(
            get: { [comparator(model.sortKey, model.ascending ? .forward : .reverse)] },
            set: { comparators in
                guard let first = comparators.first,
                      let key = SortKey.allCases.first(where: { comparator($0, .forward).keyPath == first.keyPath }) else { return }
                model.sortKey = key
                model.ascending = first.order == .forward
            }
        )
    }

    var body: some View {
        Table(of: FileItem.self, selection: $model.selection, sortOrder: sortOrder) {
            TableColumn("Name", sortUsing: comparator(.name, .forward)) { item in
                HStack(spacing: 6) {
                    Image(nsImage: item.icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                    if model.isRenaming(item) {
                        RenameField(model: model, item: item)
                    } else {
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("item.\(item.name)")
            }
            .width(min: 180, ideal: 320)
            TableColumn("Date Modified", sortUsing: comparator(.dateModified, .forward)) { item in
                Text(item.dateText).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Size", sortUsing: comparator(.size, .forward)) { item in
                Text(item.sizeText).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Kind", sortUsing: comparator(.kind, .forward)) { item in
                Text(item.kind).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 140)
        } rows: {
            ForEach(model.visibleItems) { item in
                if item.isFolder {
                    TableRow(item)
                        .itemProvider { NSItemProvider(object: item.url as NSURL) }
                        .dropDestination(for: URL.self) { urls in model.drop(urls, into: item.url) }
                } else {
                    TableRow(item)
                        .itemProvider { NSItemProvider(object: item.url as NSURL) }
                }
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if !urls.isEmpty {
                ItemMenu(model: model, urls: model.visibleItems.map(\.url).filter(urls.contains))
            }
        } primaryAction: { urls in
            model.open(model.visibleItems.map(\.url).filter(urls.contains))
        }
        .background(RightClickHandler(model: model))
        .accessibilityIdentifier("fileList")
    }
}

// Right-click selects the clicked item first, so the menu's target is the highlighted one (an unselected row only gets
// a focus ring otherwise). SwiftUI's Table also never shows the contextMenu(forSelectionType:) menu for a right-click
// below the rows, although the documentation says it does with an empty selection (measured on macOS 27 with a
// minimal Table): the background menu is popped here when the click hits no row.
// A left click in the content must also end editing in the path or search field: since the macOS 26 SDK, clicking a row
// no longer takes first responder from it, and ⌘⌫ would then edit the path instead of trashing the clicked file.
struct RightClickHandler: NSViewRepresentable {
    let model: BrowserModel

    func makeNSView(context: Context) -> HookView { HookView(model: model) }
    func updateNSView(_ view: HookView, context: Context) { view.model = model }

    final class HookView: NSView {
        var model: BrowserModel
        private var monitor: Any?

        init(model: BrowserModel) {
            self.model = model
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, event.window === self.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return event }
                return MainActor.assumeIsolated { self.handle(event) } ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            if event.type == .leftMouseDown {
                leaveOutsideField(for: event)
                return false
            }
            guard let table = enclosingTable(for: event) else {
                if let url = model.hoveredURL { select(url) }
                return false
            }
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            guard row != -1 else {
                model.selection = []
                NSMenu.popUpContextMenu(NSHostingMenu(rootView: BackgroundMenu(model: model)), with: event, for: table)
                return true
            }
            if model.visibleItems.indices.contains(row) { select(model.visibleItems[row].url) }
            return false
        }

        private func leaveOutsideField(for event: NSEvent) {
            guard let window, let field = (window.firstResponder as? NSTextView)?.delegate as? NSView,
                  !field.convert(field.bounds, to: nil).intersects(convert(bounds, to: nil))
            else { return }
            if let table = enclosingTable(for: event) { window.makeFirstResponder(table) } else { model.focusContent() }
        }

        private func select(_ url: URL) {
            if !model.selection.contains(url) { model.selection = [url] }
        }

        private func enclosingTable(for event: NSEvent) -> NSTableView? {
            guard var view = window?.contentView?.hitTest(event.locationInWindow) else { return nil }
            while !(view is NSTableView) {
                guard let parent = view.superview else { return nil }
                view = parent
            }
            return view as? NSTableView
        }
    }
}

struct FileGrid: View {
    @Bindable var model: BrowserModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 12) {
                ForEach(model.visibleItems) { item in
                    IconCell(model: model, item: item)
                }
            }
            .padding(12)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = [] }
        .contextMenu { BackgroundMenu(model: model) }
        .background(RightClickHandler(model: model))
        .focusable()
        .focusEffectDisabled()
        .accessibilityIdentifier("fileGrid")
    }
}

struct IconCell: View {
    let model: BrowserModel
    let item: FileItem

    private var selected: Bool { model.selection.contains(item.url) }

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 64, height: 64)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear))
            if model.isRenaming(item) {
                RenameField(model: model, item: item)
            } else {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor : .clear))
            }
        }
        .frame(width: 100)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open([item.url]) }
        .simultaneousGesture(TapGesture().onEnded { select() })
        .onHover { inside in
            if inside { model.hoveredURL = item.url } else if model.hoveredURL == item.url { model.hoveredURL = nil }
        }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .dropDestination(for: URL.self) { urls, _ in
            guard item.isFolder else { return false }
            model.drop(urls, into: item.url)
            return true
        }
        .contextMenu {
            ItemMenu(model: model, urls: selected ? model.selectedURLs : [item.url])
        }
        .accessibilityElement(children: model.isRenaming(item) ? .contain : .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("item.\(item.name)")
    }

    private func select() {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selected { model.selection.remove(item.url) } else { model.selection.insert(item.url) }
        } else if flags.contains(.shift), let anchor = model.visibleItems.firstIndex(where: { model.selection.contains($0.url) }),
                  let index = model.visibleItems.firstIndex(of: item) {
            model.selection = Set(model.visibleItems[min(anchor, index)...max(anchor, index)].map(\.url))
        } else {
            model.selection = [item.url]
        }
    }
}

struct ItemMenu: View {
    let model: BrowserModel
    let urls: [URL]

    private var folders: [URL] { urls.filter { model.item(at: $0)?.isFolder == true } }

    var body: some View {
        Button("Open") { model.open(urls) }
        if let first = urls.first {
            OpenWithMenu(model: model, urls: urls, apps: NSWorkspace.shared.urlsForApplications(toOpen: first),
                         defaultApp: NSWorkspace.shared.urlForApplication(toOpen: first))
        }
        Divider()
        Button("Quick Look") {
            model.selection = Set(urls)
            model.quickLookURL = urls.first
        }
        if urls.count == 1 {
            Button("Rename") { model.beginRename(urls[0]) }
        }
        Divider()
        Button("Copy") { model.copyToPasteboard(urls) }
        Button("Copy Path") { model.copyPaths(urls) }
        if !folders.isEmpty {
            Button("Add to Favorites") { folders.forEach(model.places.addFavorite) }
        }
        Divider()
        Button("Move to Trash") { model.trash(urls) }
    }
}

struct OpenWithMenu: View {
    let model: BrowserModel
    let urls: [URL]
    let apps: [URL]
    let defaultApp: URL?

    private var ordered: [URL] {
        guard let defaultApp else { return apps }
        return [defaultApp] + apps.filter { $0.path != defaultApp.path }
    }

    var body: some View {
        Menu("Open With") {
            ForEach(Array(ordered.enumerated()), id: \.offset) { index, app in
                Button {
                    model.open(urls, with: app)
                } label: {
                    let name = FileManager.default.displayName(atPath: app.path)
                    Label {
                        Text(index == 0 && defaultApp != nil ? String(localized: "\(name) (default)") : name)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    }
                }
                if index == 0 && defaultApp != nil && ordered.count > 1 { Divider() }
            }
        }
    }
}

struct BackgroundMenu: View {
    let model: BrowserModel

    var body: some View {
        Button("New Folder") { model.newFolder() }
        Button("New File") { model.newFile() }
        Divider()
        Button("Paste") { model.paste() }
            .disabled(!model.canPaste)
        Button("Move Here") { model.paste(move: true) }
            .disabled(!model.canPaste)
        Divider()
        Button("Copy Path") { model.copyPaths([model.currentURL]) }
        Button("Open in Terminal") { model.openInTerminal() }
        Divider()
        Toggle("Show Hidden Files", isOn: Binding(get: { model.showHidden }, set: { model.showHidden = $0 }))
        Button("Add to Favorites") { model.places.addFavorite(model.currentURL) }
            .disabled(model.places.isFavorite(model.currentURL))
    }
}

struct RenameField: NSViewRepresentable {
    let model: BrowserModel
    let item: FileItem

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: item.name)
        field.setAccessibilityIdentifier("renameField")
        field.cell?.setAccessibilityIdentifier("renameField")
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        // The field has no window yet: focus it once SwiftUI has inserted it.
        DispatchQueue.main.async { context.coordinator.focus(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.model = model
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, isFolder: item.isFolder) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: BrowserModel
        let isFolder: Bool
        private var finished = false

        init(model: BrowserModel, isFolder: Bool) {
            self.model = model
            self.isFolder = isFolder
        }

        func focus(_ field: NSTextField) {
            guard field.window?.makeFirstResponder(field) == true else { return }
            let name = field.stringValue
            let length = isFolder ? name.utf16.count : (name as NSString).deletingPathExtension.utf16.count
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            finished = true
            model.cancelRename()
            return true
        }

        // Fires on Return and when the field loses focus, which commits like Finder does.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard !finished, let field = notification.object as? NSTextField else { return }
            finished = true
            model.commitRename(field.stringValue)
            guard model.renamingURL != nil else { return }
            finished = false
            DispatchQueue.main.async { self.focus(field) }
        }
    }
}
