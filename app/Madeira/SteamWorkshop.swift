// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Steam Workshop items for games in Madeira Dock's Steam library. Asks Steam
// for the account's subscriptions to a game (PublishedFile.GetUserFiles,
// type "mysubscriptions"), downloads each item's content from the app's
// workshop depot with the same depot downloader games install with, and
// writes the install record Valve's client keeps for an app's Workshop
// content (steamapps/workshop/appworkshop_<appid>.acf). The game then finds
// its items through ISteamUGC, answered by Valve's client under Dock, exactly
// as on a PC. Log tag: [steam-workshop] (App IDs, item IDs, counts, sizes).

import Foundation
import SwiftUI

/// One subscribed Workshop item, as PublishedFile.GetUserFiles describes it.
struct SteamWorkshopItem: Equatable, Sendable, Identifiable {
    var id: UInt64
    var title: String = ""
    var consumerAppID: UInt32 = 0
    /// The content manifest in the app's workshop depot; 0 for legacy items.
    var manifest: UInt64 = 0
    /// Legacy single-file items: where the file is, and its name.
    var fileURL: String = ""
    var fileName: String = ""
    var fileSize: UInt64 = 0
    /// Unix seconds.
    var timeUpdated: UInt32 = 0
    var result: UInt32 = 1

    var downloadable: Bool { result == 1 && (manifest != 0 || fileURL.hasPrefix("https://")) }
}

enum SteamWorkshop {
    static let pageSize: UInt32 = 100

    /// CPublishedFile_GetUserFiles_Request: steamid = 1 (fixed64), appid = 2,
    /// page = 4, numperpage = 5, type = 6, return_short_description = 24.
    static func request(steamID: UInt64, appID: UInt32, page: UInt32) -> Data {
        var request = ProtobufEncoder()
        request.writeFixed64(fieldNumber: 1, value: steamID)
        request.writeUInt32(fieldNumber: 2, value: appID)
        request.writeUInt32(fieldNumber: 4, value: page)
        request.writeUInt32(fieldNumber: 5, value: pageSize)
        request.writeString(fieldNumber: 6, value: "mysubscriptions")
        request.writeBool(fieldNumber: 24, value: false)
        return request.data
    }

    /// CPublishedFile_GetUserFiles_Response: total = 1, publishedfiledetails = 3
    /// { result = 1, publishedfileid = 2, consumer_appid = 5, filename = 7,
    /// file_size = 8, file_url = 10, hcontent_file = 14 (fixed64), title = 16,
    /// time_updated = 20 }.
    static func parse(_ data: Data) throws -> (total: UInt32, items: [SteamWorkshopItem]) {
        var decoder = ProtobufDecoder(data)
        var total: UInt32 = 0
        var items: [SteamWorkshopItem] = []
        while let tag = try decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, .varint): total = UInt32(truncatingIfNeeded: try decoder.readVarint())
            case (3, .lengthDelimited):
                var sub = ProtobufDecoder(try decoder.readBytes())
                var item = SteamWorkshopItem(id: 0)
                while let field = try sub.readTag() {
                    switch (field.fieldNumber, field.wireType) {
                    case (1, .varint): item.result = UInt32(truncatingIfNeeded: try sub.readVarint())
                    case (2, .varint): item.id = try sub.readVarint()
                    case (2, .fixed64): item.id = try sub.readFixed64()
                    case (5, .varint): item.consumerAppID = UInt32(truncatingIfNeeded: try sub.readVarint())
                    case (7, .lengthDelimited): item.fileName = try sub.readString()
                    case (8, .varint): item.fileSize = try sub.readVarint()
                    case (10, .lengthDelimited): item.fileURL = try sub.readString()
                    case (14, .fixed64): item.manifest = try sub.readFixed64()
                    case (14, .varint): item.manifest = try sub.readVarint()
                    case (16, .lengthDelimited): item.title = String(try sub.readString().prefix(200))
                    case (20, .varint): item.timeUpdated = UInt32(truncatingIfNeeded: try sub.readVarint())
                    default: try sub.skip(wireType: field.wireType)
                    }
                }
                if item.id != 0 { items.append(item) }
                if items.count > 5_000 { throw SteamFileError.invalid("Too many Workshop items.") }
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return (total, items)
    }

    // MARK: Files

    static func workshop(steamApps: URL) -> URL { steamApps.appendingPathComponent("workshop", isDirectory: true) }
    static func content(appID: UInt32, steamApps: URL) -> URL {
        workshop(steamApps: steamApps).appendingPathComponent("content/\(appID)", isDirectory: true)
    }
    static func itemFolder(appID: UInt32, item: UInt64, steamApps: URL) -> URL {
        content(appID: appID, steamApps: steamApps).appendingPathComponent("\(item)", isDirectory: true)
    }
    static func journal(appID: UInt32, item: UInt64, steamApps: URL) -> URL {
        workshop(steamApps: steamApps).appendingPathComponent("downloads/\(appID)/\(item)", isDirectory: true)
    }
    static func recordURL(appID: UInt32, steamApps: URL) -> URL {
        workshop(steamApps: steamApps).appendingPathComponent("appworkshop_\(appID).acf")
    }

    /// A legacy item's file name, reduced to one safe path component.
    static func safeFileName(_ name: String, item: UInt64) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = last.unicodeScalars.filter { $0.value >= 32 && !":*?\"<>|".unicodeScalars.contains($0) }
        let result = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return result.isEmpty || result.utf8.count > 200 ? "\(item).bin" : result
    }

    // MARK: Install record

    struct Installed: Equatable, Sendable {
        var size: UInt64
        var timeUpdated: UInt32
        var manifest: UInt64
    }

    /// Items the record lists as installed, by item ID.
    static func readRecord(appID: UInt32, steamApps: URL) -> [UInt64: Installed] {
        guard let data = try? Data(contentsOf: recordURL(appID: appID, steamApps: steamApps)),
              var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let installed = root["AppWorkshop"]?["WorkshopItemsInstalled"]?.fields
        else { return [:] }
        var result: [UInt64: Installed] = [:]
        for (key, entry) in installed {
            guard let id = UInt64(key) else { continue }
            result[id] = Installed(size: UInt64(entry["size"]?.string ?? "") ?? 0,
                                   timeUpdated: UInt32(entry["timeupdated"]?.string ?? "") ?? 0,
                                   manifest: UInt64(entry["manifest"]?.string ?? "") ?? 0)
        }
        return result
    }

    /// Writes appworkshop_<appid>.acf in the layout Valve's client writes, so
    /// it treats the items as installed and current instead of downloading
    /// them again. Items no longer subscribed are left out.
    static func writeRecord(appID: UInt32, steamApps: URL, accountID: UInt32,
                            items: [UInt64: Installed]) throws {
        let now = UInt32(Date().timeIntervalSince1970)
        let total = items.values.reduce(UInt64(0)) { $0 + $1.size }
        let latest = items.values.map(\.timeUpdated).max() ?? 0
        var out = "\"AppWorkshop\"\n{\n"
        out += "\t\"appid\"\t\t\"\(appID)\"\n"
        out += "\t\"SizeOnDisk\"\t\t\"\(total)\"\n"
        out += "\t\"NeedsUpdate\"\t\t\"0\"\n"
        out += "\t\"NeedsDownload\"\t\t\"0\"\n"
        out += "\t\"TimeLastUpdated\"\t\t\"\(latest)\"\n"
        out += "\t\"TimeLastAppRan\"\t\t\"0\"\n"
        out += "\t\"LastBuildID\"\t\t\"0\"\n"
        out += "\t\"WorkshopItemsInstalled\"\n\t{\n"
        for (id, item) in items.sorted(by: { $0.key < $1.key }) {
            out += "\t\t\"\(id)\"\n\t\t{\n"
            out += "\t\t\t\"size\"\t\t\"\(item.size)\"\n"
            out += "\t\t\t\"timeupdated\"\t\t\"\(item.timeUpdated)\"\n"
            out += "\t\t\t\"manifest\"\t\t\"\(item.manifest)\"\n"
            out += "\t\t}\n"
        }
        out += "\t}\n\t\"WorkshopItemDetails\"\n\t{\n"
        for (id, item) in items.sorted(by: { $0.key < $1.key }) {
            out += "\t\t\"\(id)\"\n\t\t{\n"
            out += "\t\t\t\"manifest\"\t\t\"\(item.manifest)\"\n"
            out += "\t\t\t\"timeupdated\"\t\t\"\(item.timeUpdated)\"\n"
            out += "\t\t\t\"timetouched\"\t\t\"\(now)\"\n"
            out += "\t\t\t\"subscribedby\"\t\t\"\(accountID)\"\n"
            out += "\t\t}\n"
        }
        out += "\t}\n}\n"
        let url = recordURL(appID: appID, steamApps: steamApps)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(out.utf8).write(to: url, options: .atomic)
    }
}

/// Progress of one game's Workshop sync, for the game page.
struct SteamWorkshopState: Equatable {
    enum Phase: Equatable { case idle, listing, downloading, done, failed(String) }
    var phase: Phase = .idle
    var subscribed = 0
    var installed = 0
    /// Item being downloaded: its position (1-based) and progress.
    var current = 0
    /// Items this sync downloads.
    var pending = 0
    var progress = SteamDownloadProgress()
}


/// The Workshop section of a Steam game's page: subscribed items and their sync.
struct SteamWorkshopSection: View {
    let appID: Int
    @ObservedObject private var steam = SteamOwnedLibrary.shared

    var body: some View {
        if SteamOwnedLibrary.workshopEnabled {
            Section {
                rows
            } header: {
                Text("Steam Workshop")
            } footer: {
                Text("Items you subscribe to on Steam download here when this page opens, and the game finds them as it would on a PC. Subscribe or unsubscribe on the Steam website or app, then sync again.")
            }
        }
    }

    @ViewBuilder private var rows: some View {
        if !steam.signedIn {
            Text("Sign in to Steam to use the Workshop.").foregroundStyle(.secondary)
        } else if let state = steam.workshop[appID] {
            switch state.phase {
            case .idle:
                Button("Sync now") { Task { await steam.syncWorkshop(appID) } }
            case .listing:
                HStack(spacing: 10) { ProgressView(); Text("Checking subscriptions…").foregroundStyle(.secondary) }
            case .downloading:
                let p = state.progress
                ProgressView(value: Double(p.doneBytes), total: Double(max(p.totalBytes, 1))) {
                    Text("Downloading item \(state.current) of \(state.pending)")
                }
            case .done:
                Text(state.subscribed == 0 ? "No subscribed items for this game."
                     : "\(state.subscribed) subscribed item\(state.subscribed == 1 ? "" : "s"), all downloaded.")
                    .foregroundStyle(.secondary)
                Button("Sync now") { Task { await steam.syncWorkshop(appID) } }
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.orange)
                Button("Try again") { Task { await steam.syncWorkshop(appID) } }
            }
        } else {
            Text("Not synced yet.").foregroundStyle(.secondary)
                .task { await steam.syncWorkshop(appID) }
            Button("Sync now") { Task { await steam.syncWorkshop(appID) } }
        }
    }
}
