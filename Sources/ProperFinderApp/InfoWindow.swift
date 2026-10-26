import AppKit
import ProperFinderCore
import SwiftUI

struct InfoView: View {
    let url: URL
    @State private var folderSize: (bytes: Int64, items: Int)?

    private var item: FileItem? { try? FileItem(url: url) }
    private var created: Date? { try? url.resourceValues(forKeys: [.creationDateKey]).creationDate }

    private var sizeText: String {
        let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        if let size = item?.size { return format(size) }
        guard let folderSize else { return String(localized: "Calculating…") }
        let bytes = format(folderSize.bytes), items = itemCount(folderSize.items)
        return String(localized: "\(bytes) for \(items)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 64, height: 64)
                Text(url.lastPathComponent)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("info.name")
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                row("Kind", item?.kind ?? "—", id: "info.kind")
                row("Size", sizeText, id: "info.size")
                row("Where", url.deletingLastPathComponent().path, id: "info.where")
                row("Created", created?.formatted(date: .long, time: .shortened) ?? "—", id: "info.created")
                row("Modified", item?.dateModified?.formatted(date: .long, time: .shortened) ?? "—", id: "info.modified")
            }
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .task(id: url) {
            if item?.size == nil { folderSize = await directorySize(url) }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String, id: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(id)
        }
    }
}
