import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Files dropped on the island, kept until dragged out or cleared. Items point at the
/// original files and survive restarts as bookmarks — or, with "keep copies" on, at copies
/// in Application Support, so the originals can be moved or deleted.
@MainActor
@Observable
final class ShelfStore {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        var url: URL
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private let key = "shelfBookmarks"

    init() {
        let saved = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        items = saved.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Item(url: url)
        }
    }

    /// Where copies live: one folder per file, so equal names never collide.
    static let copiesFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Islet/Shelf")

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.url.standardizedFileURL))
        let copying = UserDefaults.standard.bool(forKey: "shelfKeepsCopies")
        items += urls.filter { !known.contains($0.standardizedFileURL) && !isCopy($0) }
            .compactMap { url in
                guard copying else { return Item(url: url) }
                let folder = Self.copiesFolder.appending(path: UUID().uuidString)
                let copy = folder.appending(path: url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    return Item(url: copy)
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    return Item(url: url)
                }
            }
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        deleteIfCopy(item.url)
        save()
    }

    func clear() {
        items.forEach { deleteIfCopy($0.url) }
        items = []
        save()
    }

    private func isCopy(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(Self.copiesFolder.standardizedFileURL.path + "/")
    }

    /// A copy goes with its tile; originals are never touched.
    private func deleteIfCopy(_ url: URL) {
        guard isCopy(url) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Files that were moved or deleted since they were dropped.
    func pruneMissing() {
        let present = items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if present.count != items.count {
            items = present
            save()
        }
    }

    private func save() {
        let bookmarks = items.compactMap { try? $0.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        UserDefaults.standard.set(bookmarks, forKey: key)
    }
}

/// The shelf inside the island: dropped files as tiles you can drag back out, with AirDrop
/// and Clear. While files are being dragged over it, it becomes one big drop target.
struct ShelfView: View {
    let shelf: ShelfStore
    let hasTrack: Bool
    var showControls: () -> Void = {}
    var notchHeight: CGFloat?
    let showMusic: () -> Void
    let dropped: () -> Void
    /// Keeps the island open while the share menu is up.
    var interacting: (Bool) -> Void = { _ in }
    @Environment(\.clickRouter) private var router
    @State private var targeted = false
    @State private var shareAnchor = ShareAnchor.Holder()
    @State private var tab = Tab.files
    private var clipboard: ClipboardHistory { .shared }
    private enum Tab { case files, clipboard }
    /// Dragging files in always shows the files.
    private var showsClipboard: Bool { clipboard.isEnabled && tab == .clipboard && !targeted }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if clipboard.isEnabled {
                    tabButton("Files", symbol: "tray.full.fill", tab: .files)
                    tabButton("Clipboard", symbol: "doc.on.clipboard.fill", tab: .clipboard)
                } else {
                    Label("Shelf", systemImage: "tray.full.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Spacer()
                if showsClipboard, !clipboard.entries.isEmpty {
                    button("Clear", symbol: "trash", id: "clip.clear") { clipboard.clear() }
                }
                if !showsClipboard, !shelf.items.isEmpty {
                    button("Share", symbol: "square.and.arrow.up", id: "shelf.share", action: share)
                        .background(ShareAnchor(holder: shareAnchor))
                    button("AirDrop", symbol: "dot.radiowaves.left.and.right", id: "shelf.airdrop", action: airDrop)
                    button("Clear", symbol: "trash", id: "shelf.clear") { shelf.clear() }
                }
                button("Control Center", symbol: "switch.2", id: "shelf.controls", action: showControls)
                if hasTrack { button("Now Playing", symbol: "music.note", id: "shelf.music", action: showMusic) }
            }
            if showsClipboard {
                ClipboardView(history: clipboard)
            } else if shelf.items.isEmpty || targeted {
                dropZone
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items) { item in
                            ShelfTile(item: item, preview: { ShelfPreview.shared.show(shelf.items.map(\.url), selecting: item.url) },
                                      remove: { shelf.remove(item) })
                        }
                    }
                }
            }
        }
        .padding(.top, (notchHeight ?? 0) + 12)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            load(providers)
            return true
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: targeted)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: shelf.items)
        .onAppear { shelf.pruneMissing() }
    }

    private func tabButton(_ title: String, symbol: String, tab: Tab) -> some View {
        let selected = self.tab == tab
        let select = { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.tab = tab } }
        return RoutedButton("shelf.tab.\(title)", action: select) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0)))
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.white.opacity(targeted ? 0.85 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(targeted ? 0.12 : 0.04)))
            .overlay {
                Label(targeted ? "Drop to keep here" : "Drag files here to keep them", systemImage: "arrow.down.doc.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(targeted ? 1 : 0.65))
            }
            .scaleEffect(targeted ? 1.02 : 1)
    }

    private func button(_ help: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: ClickRouter.guarded(router, id, action)) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(GlassIconButtonStyle(diameter: 26, look: .highlight))
        .routedClick(id, action: action)
        .help(help)
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in
                    shelf.add([url])
                    dropped()
                }
            }
        }
    }

    /// The system share menu (AirDrop, Messages, Mail, Notes…) under the Share button.
    private func share() {
        guard let view = shareAnchor.view, !shelf.items.isEmpty else { return }
        NSApp.activate()
        interacting(true)
        ShareMenu.shared.show(shelf.items.map(\.url), from: view) { interacting(false) }
    }

    private func airDrop() {
        guard let service = NSSharingService(named: .sendViaAirDrop) else { return }
        let urls = shelf.items.map(\.url)
        guard service.canPerform(withItems: urls) else { return }
        NSApp.activate()
        service.perform(withItems: urls)
    }
}

/// Quick Look for shelf files. The panel normally asks the responder chain for its data;
/// Islet's island panel never becomes key, so this sets itself as the source directly.
@MainActor
final class ShelfPreview: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = ShelfPreview()
    private var urls: [URL] = []

    func show(_ urls: [URL], selecting url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        NSApp.activate()
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = urls.firstIndex(of: url) ?? 0
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}

/// Hands the Share button's AppKit view to the share menu, which opens beneath it.
struct ShareAnchor: NSViewRepresentable {
    final class Holder {
        weak var view: NSView?
    }

    let holder: Holder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        holder.view = view
    }
}

/// Shows `NSSharingServicePicker` and reports when it closes, whether a service was
/// chosen or the menu was dismissed.
@MainActor
final class ShareMenu: NSObject, @preconcurrency NSSharingServicePickerDelegate {
    static let shared = ShareMenu()
    private var closed: (() -> Void)?

    func show(_ urls: [URL], from view: NSView, closed: @escaping () -> Void) {
        self.closed?()
        self.closed = closed
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = self
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        closed?()
        closed = nil
    }
}

/// One file: its Finder icon and name. Drag it out to move it on; × removes it.
private struct ShelfTile: View {
    let item: ShelfStore.Item
    let preview: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 40, height: 40)
            Text(item.url.lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 66)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hovering ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .routedClick("shelf.remove.\(item.id)", action: remove)
                    .onTapGesture(perform: remove)
            }
        }
        .overlay(alignment: .topLeading) {
            if hovering {
                Image(systemName: "eye.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .routedClick("shelf.preview.\(item.id)", action: preview)
                    .onTapGesture(perform: preview)
                    .help("Quick Look")
            }
        }
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .help(item.url.path)
    }
}
