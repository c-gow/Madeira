import SwiftUI
import UniformTypeIdentifiers

/// Folders the user picked outside the app, usually on a USB or SSD drive.
///
/// iOS only lets the app reach them through the folder picker. The picked URL
/// is kept as a bookmark in Documents/madeira-external.json, and on every launch
/// (before the wineserver starts) each one is opened again and linked into the
/// prefix twice: as drive_c/External/<name>, so the library and the executable
/// browser work unchanged, and as dosdevices/<letter>:, so Windows lists it as a
/// drive. A folder whose drive is not plugged in is left out until next time.
struct ExternalFolder: Codable, Identifiable {
    var id = UUID()
    var name: String
    var letter: String
    var bookmark: Data
}

final class ExternalDrives: ObservableObject {
    static let shared = ExternalDrives()
    @Published private(set) var folders: [ExternalFolder] = []
    /// Folders opened this launch, by id, with the path they resolved to.
    @Published private(set) var mounted: [UUID: URL] = [:]

    private static var store: URL { LibraryModel.documents.appendingPathComponent("madeira-external.json") }
    static var linkRoot: URL { MadeiraDock.drive.appendingPathComponent("External", isDirectory: true) }
    private static var dosdevices: URL { MadeiraDock.prefix.appendingPathComponent("dosdevices", isDirectory: true) }

    private init() {
        if let data = try? Data(contentsOf: Self.store),
           let list = try? JSONDecoder().decode([ExternalFolder].self, from: data) { folders = list }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) { try? data.write(to: Self.store, options: .atomic) }
    }

    /// Opens every saved folder and refreshes the links. Safe to call again; it
    /// must run before the wineserver starts for Windows to list the drives.
    func mountAll() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.linkRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.dosdevices, withIntermediateDirectories: true)
        var changed = false
        for i in folders.indices {
            let folder = folders[i]
            if mounted[folder.id] != nil { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: folder.bookmark, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else {
                LogStore.shared.log("[external] \(folder.name) is not available")
                unlink(folder)
                continue
            }
            if stale, let fresh = try? url.bookmarkData() { folders[i].bookmark = fresh; changed = true }
            mounted[folder.id] = url
            link(folder, to: url)
            LogStore.shared.log("[external] \(folder.letter.uppercased()): \(folder.name) -> \(url.path)")
        }
        if changed { save() }
    }

    /// Adds a folder picked with the folder picker and links it right away.
    func add(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else { throw LibraryError.message("Madeira could not open that folder.") }
        let bookmark: Data
        do { bookmark = try url.bookmarkData() } catch { url.stopAccessingSecurityScopedResource(); throw error }
        let used = Set(folders.map(\.letter))
        guard let letter = "defghijklmnopqrstuvwxy".map(String.init).first(where: { !used.contains($0) }) else {
            url.stopAccessingSecurityScopedResource()
            throw LibraryError.message("No free drive letters.")
        }
        var name = url.lastPathComponent.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined()
        if name.isEmpty { name = "Drive" }
        let base = name; var n = 2
        while folders.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { name = "\(base) \(n)"; n += 1 }
        let folder = ExternalFolder(name: name, letter: letter, bookmark: bookmark)
        folders.append(folder); save()
        mounted[folder.id] = url
        link(folder, to: url)
        LogStore.shared.log("[external] added \(letter.uppercased()): \(name) -> \(url.path)")
    }

    func remove(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        unlink(folder)
        mounted.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        folders.removeAll { $0.id == id }; save()
    }

    private func link(_ folder: ExternalFolder, to url: URL) {
        let fm = FileManager.default
        for (path, target) in [(Self.linkRoot.appendingPathComponent(folder.name).path, url.path),
                               (Self.dosdevices.appendingPathComponent(folder.letter + ":").path, url.path)] {
            try? fm.removeItem(atPath: path)
            try? fm.createSymbolicLink(atPath: path, withDestinationPath: target)
        }
    }

    private func unlink(_ folder: ExternalFolder) {
        // Only links are removed, never what they point at.
        for path in [Self.linkRoot.appendingPathComponent(folder.name).path,
                     Self.dosdevices.appendingPathComponent(folder.letter + ":").path] {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    /// The real roots of the folders opened this launch.
    var roots: [(name: String, path: String)] {
        folders.compactMap { f in mounted[f.id].map { (f.name, $0.resolvingSymlinksInPath().path) } }
    }
}

/// Settings › External drives.
struct ExternalDrivesSection: View {
    @ObservedObject private var drives = ExternalDrives.shared
    @State private var picking = false
    @State private var error: String?

    var body: some View {
        Section {
            ForEach(drives.folders) { folder in
                HStack {
                    Text(folder.letter.uppercased() + ":").font(.body.monospaced())
                    Text(folder.name)
                    Spacer()
                    Text(drives.mounted[folder.id] == nil ? "Not connected" : "Connected").foregroundStyle(.secondary)
                }
                .swipeActions { Button("Remove", role: .destructive) { drives.remove(folder.id) } }
            }
            Button("Add folder") { picking = true }
            if let error { Text(error).foregroundStyle(.red) }
        } header: { Text("External drives") } footer: {
            Text("Pick a folder on a USB or SSD drive. Windows sees it as a drive letter and as C:\\External\\<name>, so games there can be added to the library. Unplugging the drive while a game runs will close it. Restart Madeira after adding a folder for Windows to list the new drive.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            do { try drives.add(try result.get()); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}
