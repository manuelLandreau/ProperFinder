import AppKit
import QuickLook
import SwiftUI

struct LaunchOptions {
    var root: URL?
    var uiTesting = false

    init(_ arguments: [String]) {
        uiTesting = arguments.contains("--ui-testing")
        if let index = arguments.firstIndex(of: "--root"), index + 1 < arguments.count {
            root = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
        }
    }
}

let uiTestingSuite = "fr.manuellandreau.properfinder.uitests"

public struct ProperFinderApp: App {
    private let launch = LaunchOptions(CommandLine.arguments)
    @State private var places: Places

    public init() {
        // Otherwise AppKit takes the --root folder for a document to open and never creates the initial window.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        var defaults = UserDefaults.standard
        if launch.uiTesting, let suite = UserDefaults(suiteName: uiTestingSuite) {
            suite.removePersistentDomain(forName: uiTestingSuite)
            defaults = suite
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame \(uiTestingSuite)") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        _places = State(initialValue: Places(defaults: defaults))
    }

    public var body: some Scene {
        // Frames are autosaved in the standard domain under the window group id: UI tests get their own id so they
        // neither pick up nor overwrite the frame of the everyday app.
        WindowGroup(id: launch.uiTesting ? uiTestingSuite : "browser") {
            BrowserWindow(places: places, start: launch.root ?? places.home)
        }
        .defaultSize(width: 1100, height: 700)
        .restorationBehavior(launch.uiTesting ? .disabled : .automatic)
        .commands { BrowserCommands() }
    }
}

struct BrowserWindow: View {
    @State private var model: BrowserModel

    init(places: Places, start: URL) {
        _model = State(initialValue: BrowserModel(places: places, start: start))
    }

    var body: some View {
        BrowserView(model: model)
            // Otherwise the window gives initial focus to its first key view, the sidebar.
            .task { model.focusContent() }
    }
}

struct BrowserView: View {
    @Bindable var model: BrowserModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 300)
        } detail: {
            VStack(spacing: 0) {
                PathField(model: model)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
                if model.isTrash {
                    TrashHeader(model: model)
                }
                FileContent(model: model)
                Divider()
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("statusBar")
            }
        }
        .navigationTitle(model.title)
        .toolbar { BrowserToolbar(model: model) }
        .focusedSceneValue(\.browser, model)
        .quickLookPreview($model.quickLookURL, in: model.selectedURLs)
        .alert(Text("The operation can't be completed."), isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(Text("Are you sure you want to permanently erase the items in the Trash?"), isPresented: $model.confirmingEmptyTrash) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can't undo this action.")
        }
    }
}

struct TrashHeader: View {
    let model: BrowserModel

    var body: some View {
        HStack {
            Text("Trash").font(.headline)
            Spacer()
            Button("Empty…") { model.confirmingEmptyTrash = true }
                .disabled(model.items.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        Divider()
    }
}

struct BrowserToolbar: ToolbarContent {
    @Bindable var model: BrowserModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(model.backStack.isEmpty)
                .help("Back")
                .accessibilityIdentifier("backButton")
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(model.forwardStack.isEmpty)
                .help("Forward")
                .accessibilityIdentifier("forwardButton")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $model.viewMode) {
                Label("as List", systemImage: "list.bullet").tag(ViewMode.list)
                Label("as Icons", systemImage: "square.grid.2x2").tag(ViewMode.icons)
            }
            .pickerStyle(.segmented)
            .help("Change the item view")
            .accessibilityIdentifier("viewModePicker")
            Toggle(isOn: $model.showHidden) {
                Label("Show Hidden Files", systemImage: model.showHidden ? "eye" : "eye.slash")
            }
            .help("Show Hidden Files")
            .accessibilityIdentifier("hiddenFilesToggle")
            SearchField(text: $model.searchText, focusRequest: model.searchFocusRequest)
                .frame(minWidth: 100, idealWidth: 180, maxWidth: 220)
        }
    }
}

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: "Search")
        field.setAccessibilityIdentifier("searchField")
        field.cell?.setAccessibilityIdentifier("searchField")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusRequest: focusRequest) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focusRequest: Int

        init(text: Binding<String>, focusRequest: Int) {
            self.text = text
            self.focusRequest = focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

struct BrowserFocusKey: FocusedValueKey {
    typealias Value = BrowserModel
}

extension FocusedValues {
    var browser: BrowserModel? {
        get { self[BrowserFocusKey.self] }
        set { self[BrowserFocusKey.self] = newValue }
    }
}
