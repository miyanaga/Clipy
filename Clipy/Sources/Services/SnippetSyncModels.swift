//
//  SnippetSyncModels.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Copyright © 2015-2026 Clipy Project.
//

import Foundation
import CryptoKit

// MARK: - Entity Kind
enum SyncEntityKind: String, Codable {
    case folder
    case snippet
}

// MARK: - Items
protocol SyncMergeableItem: Codable, Equatable {
    static var kind: SyncEntityKind { get }
    var identifier: String { get }
    var updatedAt: Date { get set }
    var contentHash: String { get }
}

struct SyncFolderItem: SyncMergeableItem {
    static let kind = SyncEntityKind.folder

    var identifier: String
    var title: String
    var enable: Bool
    var index: Int
    var updatedAt: Date

    var contentHash: String {
        return SnippetSyncHash.digest(of: [identifier, title, String(enable), String(index)])
    }
}

struct SyncSnippetItem: SyncMergeableItem {
    static let kind = SyncEntityKind.snippet

    var identifier: String
    var folderIdentifier: String
    var title: String
    var content: String
    var enable: Bool
    var index: Int
    var updatedAt: Date

    var contentHash: String {
        return SnippetSyncHash.digest(of: [identifier, folderIdentifier, title, content, String(enable), String(index)])
    }
}

struct SyncTombstone: Codable, Hashable {
    var identifier: String
    var kind: SyncEntityKind
    var deletedAt: Date
}

// MARK: - Payload
struct SyncPayload: Codable, Equatable {
    var formatVersion = 1
    var exportedAt: Date
    var folders: [SyncFolderItem]
    var snippets: [SyncSnippetItem]
    var tombstones: [SyncTombstone]

    static func empty(exportedAt: Date) -> SyncPayload {
        return SyncPayload(exportedAt: exportedAt, folders: [], snippets: [], tombstones: [])
    }
}

// MARK: - Sync State
// Snapshot of the last successfully synced content, kept locally so the next
// merge can tell "edited since last sync" from "untouched" and "deleted locally"
// from "added remotely".
struct SyncStateItem: Codable {
    var kind: SyncEntityKind
    var hash: String
    var updatedAt: Date
}

struct SyncState: Codable {
    var directoryPath: String
    var items: [String: SyncStateItem]

    static func empty(directoryPath: String) -> SyncState {
        return SyncState(directoryPath: directoryPath, items: [:])
    }

    static func from(payload: SyncPayload, directoryPath: String) -> SyncState {
        var items = [String: SyncStateItem]()
        payload.folders.forEach { items[$0.identifier] = SyncStateItem(kind: .folder, hash: $0.contentHash, updatedAt: $0.updatedAt) }
        payload.snippets.forEach { items[$0.identifier] = SyncStateItem(kind: .snippet, hash: $0.contentHash, updatedAt: $0.updatedAt) }
        return SyncState(directoryPath: directoryPath, items: items)
    }
}

// MARK: - Hash
enum SnippetSyncHash {
    static func digest(of fields: [String]) -> String {
        // 0x1f (unit separator) keeps ["ab","c"] distinct from ["a","bc"]
        let joined = fields.joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Merge
enum SnippetSyncMerge {

    // Tombstones older than this are garbage collected; a machine offline
    // longer than this may resurrect items deleted elsewhere.
    static let tombstoneLifetime: TimeInterval = 180 * 24 * 60 * 60

    struct Result {
        var payload: SyncPayload
        var localChanged: Bool
        var remoteChanged: Bool
    }

    /// Assigns updatedAt to a fresh local snapshot: unchanged items keep the
    /// timestamp recorded in the state, changed or unknown items get `now`.
    static func attributeUpdatedAt<T: SyncMergeableItem>(_ items: [T], state: SyncState, now: Date) -> [T] {
        return items.map { item in
            var item = item
            if let stateItem = state.items[item.identifier], stateItem.hash == item.contentHash {
                item.updatedAt = stateItem.updatedAt
            } else {
                item.updatedAt = now
            }
            return item
        }
    }

    /// Three-way merge of the local snapshot and the remote bundle against the
    /// last-synced state. Per-item last-writer-wins; deletions propagate via
    /// tombstones and via items that disappeared locally since the last sync.
    static func merge(local: SyncPayload, remote: SyncPayload?, state: SyncState, now: Date) -> Result {
        let remotePayload = remote ?? SyncPayload.empty(exportedAt: .distantPast)

        let folderResult = mergeItems(local: local.folders,
                                      remote: remotePayload.folders,
                                      tombstones: remotePayload.tombstones,
                                      state: state,
                                      now: now)
        let snippetResult = mergeItems(local: local.snippets,
                                       remote: remotePayload.snippets,
                                       tombstones: remotePayload.tombstones,
                                       state: state,
                                       now: now)

        let folders = folderResult.items.sorted { ($0.index, $0.identifier) < ($1.index, $1.identifier) }
        var snippets = snippetResult.items
        var tombstones = folderResult.tombstones + snippetResult.tombstones

        // Referential integrity: a snippet whose folder was deleted follows the folder.
        let folderIds = Set(folders.map { $0.identifier })
        let orphans = snippets.filter { !folderIds.contains($0.folderIdentifier) }
        if !orphans.isEmpty {
            let folderTombstones = Dictionary(uniqueKeysWithValues: tombstones.filter { $0.kind == .folder }.map { ($0.identifier, $0) })
            snippets.removeAll { !folderIds.contains($0.folderIdentifier) }
            orphans.forEach { orphan in
                let deletedAt = folderTombstones[orphan.folderIdentifier]?.deletedAt ?? now
                tombstones.append(SyncTombstone(identifier: orphan.identifier, kind: .snippet, deletedAt: deletedAt))
            }
        }
        snippets.sort { ($0.folderIdentifier, $0.index, $0.identifier) < ($1.folderIdentifier, $1.index, $1.identifier) }
        tombstones.sort { ($0.identifier, $0.kind.rawValue) < ($1.identifier, $1.kind.rawValue) }

        let merged = SyncPayload(exportedAt: now, folders: folders, snippets: snippets, tombstones: tombstones)
        let localChanged = !isSameContent(folders: local.folders, snippets: local.snippets, as: merged)
        let remoteChanged = remote == nil
            || !isSameContent(folders: remotePayload.folders, snippets: remotePayload.snippets, as: merged)
            || Set(remotePayload.tombstones) != Set(merged.tombstones)
        return Result(payload: merged, localChanged: localChanged, remoteChanged: remoteChanged)
    }

    /// Last-writer-wins union of two bundles (used for iCloud conflict copies,
    /// where no meaningful base state exists).
    static func union(_ lhs: SyncPayload, _ rhs: SyncPayload, now: Date) -> SyncPayload {
        let folders = unionItems(lhs.folders, rhs.folders)
        let snippets = unionItems(lhs.snippets, rhs.snippets)
        var tombstonesById = [String: SyncTombstone]()
        (lhs.tombstones + rhs.tombstones).forEach { tombstone in
            if let existing = tombstonesById[tombstone.identifier], existing.deletedAt >= tombstone.deletedAt { return }
            tombstonesById[tombstone.identifier] = tombstone
        }

        // A tombstone deletes items older than it; a newer item drops the tombstone.
        let survivingFolders = folders.filter { item in
            guard let tombstone = tombstonesById[item.identifier] else { return true }
            return item.updatedAt > tombstone.deletedAt
        }
        let survivingSnippets = snippets.filter { item in
            guard let tombstone = tombstonesById[item.identifier] else { return true }
            return item.updatedAt > tombstone.deletedAt
        }
        let survivorIds = Set(survivingFolders.map { $0.identifier } + survivingSnippets.map { $0.identifier })
        let tombstones = tombstonesById.values.filter { !survivorIds.contains($0.identifier) }

        return SyncPayload(exportedAt: now,
                           folders: survivingFolders,
                           snippets: survivingSnippets,
                           tombstones: Array(tombstones))
    }

    // MARK: - Private
    private struct ItemMergeResult<T: SyncMergeableItem> {
        var items: [T]
        var tombstones: [SyncTombstone]
    }

    private static func mergeItems<T: SyncMergeableItem>(local: [T], remote: [T], tombstones: [SyncTombstone], state: SyncState, now: Date) -> ItemMergeResult<T> {
        let localById = Dictionary(uniqueKeysWithValues: local.map { ($0.identifier, $0) })
        let remoteById = Dictionary(uniqueKeysWithValues: remote.map { ($0.identifier, $0) })
        let tombstoneById = Dictionary(uniqueKeysWithValues: tombstones.filter { $0.kind == T.kind }.map { ($0.identifier, $0) })

        var identifiers = Set(localById.keys)
        identifiers.formUnion(remoteById.keys)
        identifiers.formUnion(tombstoneById.keys)

        var items = [T]()
        var mergedTombstones = [SyncTombstone]()

        for identifier in identifiers {
            let localItem = localById[identifier]
            let remoteItem = remoteById[identifier]
            let tombstone = tombstoneById[identifier]
            let stateItem = state.items[identifier]

            switch (localItem, remoteItem) {
            case let (localItem?, remoteItem?):
                let winner = localItem.updatedAt >= remoteItem.updatedAt ? localItem : remoteItem
                if let tombstone = tombstone, tombstone.deletedAt > winner.updatedAt {
                    mergedTombstones.append(tombstone)
                } else {
                    items.append(winner)
                }
            case let (localItem?, nil):
                if let tombstone = tombstone, tombstone.deletedAt >= localItem.updatedAt {
                    // Deleted on another machine after our copy was last touched
                    mergedTombstones.append(tombstone)
                } else {
                    // New local item, local edit after a remote deletion, or a
                    // remote bundle that lost the item without a tombstone —
                    // in every case keeping the data is the safe choice.
                    items.append(localItem)
                }
            case let (nil, remoteItem?):
                if let stateItem = stateItem, remoteItem.updatedAt <= stateItem.updatedAt {
                    // We synced this item before and it is gone from the local
                    // Realm: the user deleted it here. Propagate the deletion.
                    mergedTombstones.append(SyncTombstone(identifier: identifier, kind: T.kind, deletedAt: now))
                } else if let tombstone = tombstone, tombstone.deletedAt >= remoteItem.updatedAt {
                    mergedTombstones.append(tombstone)
                } else {
                    // New remote item, or edited remotely after we deleted it
                    // locally (edit wins over delete).
                    items.append(remoteItem)
                }
            case (nil, nil):
                if let tombstone = tombstone, now.timeIntervalSince(tombstone.deletedAt) < tombstoneLifetime {
                    mergedTombstones.append(tombstone)
                }
            }
        }
        return ItemMergeResult(items: items, tombstones: mergedTombstones)
    }

    private static func unionItems<T: SyncMergeableItem>(_ lhs: [T], _ rhs: [T]) -> [T] {
        var byId = [String: T]()
        (lhs + rhs).forEach { item in
            if let existing = byId[item.identifier], existing.updatedAt >= item.updatedAt { return }
            byId[item.identifier] = item
        }
        return Array(byId.values)
    }

    private static func isSameContent(folders: [SyncFolderItem], snippets: [SyncSnippetItem], as payload: SyncPayload) -> Bool {
        let lhsFolders = Set(folders.map { $0.contentHash })
        let lhsSnippets = Set(snippets.map { $0.contentHash })
        return lhsFolders == Set(payload.folders.map { $0.contentHash }) && lhsSnippets == Set(payload.snippets.map { $0.contentHash })
    }
}
