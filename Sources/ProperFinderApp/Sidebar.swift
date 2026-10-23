import AppKit
import ProperFinderCore
import SwiftUI
import UniformTypeIdentifiers

struct Sidebar: View {
    let model: BrowserModel
    private var places: Places { model.places }

    var selection: Binding<String?> {
        Binding(
            get: { places.all.first { $0.url.path == model.currentURL.path }?.accessibilityID },
            set: { id in
                if let id, let url = places.url(named: id) { model.navigate(to: url) }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section("Favorites") {
                ForEach(places.standard, id: \.accessibilityID) { row($0) }
                ForEach(places.favorites, id: \.url.path) { location in
                    row(location)
                        .contextMenu {
                            Button("Remove from Favorites") { places.removeFavorite(location.url) }
                        }
                }
                .onMove { places.moveFavorites(fromOffsets: $0, toOffset: $1) }
                .onInsert(of: [.fileURL]) { _, providers in
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            guard let url, url.hasDirectoryPath else { return }
                            Task { @MainActor in places.addFavorite(url) }
                        }
                    }
                }
            }
            if !places.cloud.isEmpty {
                Section("Cloud") {
                    ForEach(places.cloud, id: \.accessibilityID) { row($0) }
                }
            }
            if !places.volumes.isEmpty {
                Section("Locations") {
                    ForEach(places.volumes, id: \.accessibilityID) { volume in
                        row(volume)
                    }
                }
            }
            Section {
                row(places.trash)
                    .contextMenu {
                        Button("Empty Trash…") { model.confirmingEmptyTrash = true }
                    }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar")
    }

    private func row(_ location: SidebarLocation) -> some View {
        HStack {
            Label(location.name, systemImage: location.symbol)
                .help(location.detail ?? location.url.path)
                .padding(.vertical, 3)
            Spacer()
            if location.isEjectable {
                Button {
                    do { try places.eject(location) } catch { model.errorMessage = error.localizedDescription }
                } label: {
                    Image(systemName: "eject")
                }
                .buttonStyle(.borderless)
                .help("Eject")
            }
        }
        .tag(location.accessibilityID)
        .dropDestination(for: URL.self) { urls, _ in
            model.drop(urls, into: location.url)
            return true
        }
        .accessibilityIdentifier(location.accessibilityID)
    }
}
