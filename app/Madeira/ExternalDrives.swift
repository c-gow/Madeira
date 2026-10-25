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
    /// Madeira's Steam downloads go to <folder>/SteamLibrary on this drive.
    var steamInstalls: Bool? = nil
}

final class ExternalDrives: ObservableObject {
    static let shared = ExternalDrives()
    @Published private(set) var folders: [ExternalFolder] = []
    /// Folders opened this launch, by id, with the path they resolved to.
    @Published private(set) var mounted: [UUID: URL] = [:]

    private static var store: URL { LibraryModel.documents.appendingPathComponent("madeira-external.json") }
    static var linkRoot: URL { MadeiraDock.drive.appendingPathComponent("External", isDirectory: true) }
    private static var dosdevices: URL { MadeiraDock.prefix.appendingPathComponent("dosdevices", isDirectory: true) }

    /// Steam libraries (drive_c-relative steamapps folders) on the drives opened
    /// this launch, and the one Steam downloads go to. Read from any thread
    /// (MadeiraDock.games runs off the main thread), so kept behind a lock.
    private static let lock = NSLock()
    private static var libraries: [String] = []
    private static var installTarget: String?
    static var steamLibraries: [String] { lock.lock(); defer { lock.unlock() }; return libraries }
    /// The library Madeira's Steam downloads go to, or nil for drive_c's own.
    static var steamInstallLibrary: String? { lock.lock(); defer { lock.unlock() }; return installTarget }
    /// Where Steam libraries are looked for inside a picked folder.
    private static let libraryFolders = ["", "SteamLibrary", "Steam", "Program Files (x86)/Steam", "Program Files/Steam"]

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
        refreshSteam()
    }

    /// Finds the Steam libraries on the opened drives, makes the chosen download
    /// folder, and lists them all in the Steam client's libraryfolders.vdf so
    /// Valve's client (started by Madeira Dock) can start their games.
    func refreshSteam() {
        let fm = FileManager.default
        var found: [String] = [], target: String?
        for folder in folders {
            guard let url = mounted[folder.id] else { continue }
            if folder.steamInstalls == true {
                try? fm.createDirectory(at: url.appendingPathComponent("SteamLibrary/steamapps/common", isDirectory: true), withIntermediateDirectories: true)
                target = "External/\(folder.name)/SteamLibrary/steamapps"
            }
            for sub in Self.libraryFolders {
                let apps = sub.isEmpty ? "steamapps" : sub + "/steamapps"
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.appendingPathComponent(apps).path, isDirectory: &isDir), isDir.boolValue {
                    found.append("External/\(folder.name)/" + apps)
                }
            }
        }
        Self.lock.lock(); Self.libraries = found; Self.installTarget = target; Self.lock.unlock()
        Self.listInSteamClient(found.map { String($0.dropLast("/steamapps".count)) })
        LogStore.shared.log("[external] steam libraries=\(found.count) install=\(target ?? "drive_c")")
    }

    /// Adds `C:\<folder>` entries for the libraries Valve's client does not list yet.
    private static func listInSteamClient(_ relative: [String]) {
        guard !relative.isEmpty else { return }
        let vdf = MadeiraDock.drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot + "/steamapps/libraryfolders.vdf")
        func windows(_ r: String) -> String { "C:\\" + r.replacingOccurrences(of: "/", with: "\\") }
        var text = (try? String(contentsOf: vdf, encoding: .utf8)) ?? ""
        var entries: [String: SteamValue]?
        if var parser = try? SteamKeyValues(Data(text.utf8)), let root = try? parser.read() { entries = root["libraryfolders"]?.fields }
        if entries == nil { text = "\"libraryfolders\"\n{\n}\n" }
        var listed = Set((entries ?? [:]).values.compactMap { $0["path"]?.string?.replacingOccurrences(of: "\\\\", with: "\\").lowercased() })
        var next = (entries ?? [:]).keys.compactMap { Int($0) }.max().map { $0 + 1 } ?? 0
        var changed = false
        // The client's own library comes first.
        for path in [windows(SteamRuntimeFiles.relativeRoot)] + relative.map(windows) where !listed.contains(path.lowercased()) {
            text = insert(entry: path, index: next, into: text); next += 1; changed = true
            listed.insert(path.lowercased())
        }
        guard changed else { return }
        try? FileManager.default.createDirectory(at: vdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: vdf, atomically: true, encoding: .utf8)
    }

    private static func insert(entry path: String, index: Int, into text: String) -> String {
        guard let end = text.range(of: "}", options: .backwards) else { return text }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
        let block = "\t\"\(index)\"\n\t{\n\t\t\"path\"\t\t\"\(escaped)\"\n\t\t\"apps\"\n\t\t{\n\t\t}\n\t}\n"
        var out = text; out.insert(contentsOf: block, at: end.lowerBound); return out
    }

    /// Sends Madeira's Steam downloads to this folder (nil: back to drive_c).
    func setSteamInstalls(_ id: UUID?) {
        for i in folders.indices { folders[i].steamInstalls = folders[i].id == id ? true : nil }
        save(); refreshSteam()
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
        refreshSteam()
        LogStore.shared.log("[external] added \(letter.uppercased()): \(name) -> \(url.path)")
    }

    func remove(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        unlink(folder)
        mounted.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        folders.removeAll { $0.id == id }; save()
        refreshSteam()
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

/// Games already on an external folder: the programs that look like a game's
/// own executable, a few folders deep. Steam libraries are left to Steam.
enum ExternalGameScan {
    private static let skipNames = ["unins", "setup", "install", "redist", "vcredist", "vc_redist", "dxsetup", "directx",
                                    "dotnet", "crash", "report", "update", "patch", "launcherhelper", "helper", "cef",
                                    "touchup", "easyanticheat", "battleye", "ue4prereq", "prereq", "config", "settings"]
    private static let skipFolders: Set<String> = ["steamapps", "steamlibrary", "steam", "_commonredist", "commonredist", "redist",
                                                   "redistributables", "directx", "dotnet", "vcredist", "support", "__installer",
                                                   "windows", "system32", "$recycle.bin", "engine"]

    /// Folder name relative to the root, with the programs found in it.
    static func scan(_ root: URL, depth: Int = 3) -> [URL] {
        var found: [URL] = []
        walk(root, depth: depth, into: &found)
        return found
    }

    private static func walk(_ folder: URL, depth: Int, into found: inout [URL]) {
        guard found.count < 500, let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else { return }
        for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = item.lastPathComponent.lowercased()
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if depth > 0, !skipFolders.contains(name) { walk(item, depth: depth - 1, into: &found) }
            } else if item.pathExtension.lowercased() == "exe", !skipNames.contains(where: { name.hasPrefix($0) || name.contains("_" + $0) || name.contains("-" + $0) }) {
                found.append(item)
            }
        }
    }
}

/// Lists the games found on one external folder and adds the chosen ones.
struct ExternalGamesSheet: View {
    let folder: ExternalFolder
    let root: URL
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = LibraryModel.shared
    @State private var found: [URL]?
    @State private var chosen: Set<URL> = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let found {
                    if found.isEmpty { Text("No games found. Steam games on this drive show up in the Steam section.").foregroundStyle(.secondary) }
                    ForEach(found, id: \.self) { url in
                        let added = isAdded(url)
                        Button { if chosen.contains(url) { chosen.remove(url) } else { chosen.insert(url) } } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                    Text(String(url.path.dropFirst(root.path.count + 1))).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if added { Text("Added").foregroundStyle(.secondary) }
                                else if chosen.contains(url) { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(added)
                    }
                } else {
                    HStack { ProgressView(); Text("Looking for games") }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(folder.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add \(chosen.count)") { add() }.disabled(chosen.isEmpty) }
            }
        }
        .task {
            let root = root
            found = await Task.detached(priority: .userInitiated) { ExternalGameScan.scan(root) }.value
        }
    }

    private func isAdded(_ url: URL) -> Bool {
        guard let relative = LibraryModel.relativeToDrive(url) else { return false }
        return library.entries.contains { $0.relativePath.caseInsensitiveCompare(relative) == .orderedSame }
    }

    private func add() {
        var failed: [String] = []
        for url in chosen.sorted(by: { $0.path < $1.path }) {
            do {
                var entry = try LibraryModel.inspect(url)
                // A program's own name is often generic: use its folder's.
                let parent = url.deletingLastPathComponent()
                if parent.path != root.path { entry.title = parent.lastPathComponent }
                library.save(entry)
            } catch { failed.append(url.lastPathComponent + ": " + error.localizedDescription) }
        }
        LogStore.shared.log("[external] added games=\(chosen.count - failed.count) from \(folder.name)")
        if failed.isEmpty { dismiss() } else { error = failed.joined(separator: "\n"); chosen = [] }
    }
}

/// Settings › External drives.
struct ExternalDrivesSection: View {
    @ObservedObject private var drives = ExternalDrives.shared
    @State private var picking = false
    @State private var error: String?
    @State private var scanning: ExternalFolder?

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
                if drives.mounted[folder.id] != nil {
                    Button("Find games on \(folder.name)") { scanning = folder }
                }
            }
            Button("Add drive or folder") { picking = true }
            if !drives.folders.isEmpty {
                Picker("Install Steam games on", selection: Binding(
                    get: { drives.folders.first { $0.steamInstalls == true }?.id },
                    set: { drives.setSteamInstalls($0) })) {
                    Text("This iPhone").tag(UUID?.none)
                    ForEach(drives.folders) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        } header: { Text("External drives") } footer: {
            Text("Pick a folder on a USB or SSD drive, or a whole drive that already has games on it. Windows sees it as a drive letter and as C:\\External\\<name>. Find games adds the games on it to the library; Steam libraries on it (steamapps or SteamLibrary) show up in the Steam section. Steam games can be installed into <name>\\SteamLibrary. Unplugging the drive while a game runs will close it. Restart Madeira after adding a folder for Windows to list the new drive.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            do {
                try drives.add(try result.get()); error = nil
                SteamGamesModel.shared.refresh()
                // Offer the games already on it.
                scanning = drives.folders.last
            } catch { self.error = error.localizedDescription }
        }
        .sheet(item: $scanning) { folder in
            if let root = drives.mounted[folder.id] { ExternalGamesSheet(folder: folder, root: root.resolvingSymlinksInPath()) }
        }
    }
}
