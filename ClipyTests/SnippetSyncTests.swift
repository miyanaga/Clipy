import Foundation
import CryptoKit
import RealmSwift
import Testing
@testable import Clipy

struct SnippetSyncMergeTests {

    // MARK: - Helpers
    private func folder(_ identifier: String, title: String = "folder", index: Int = 0, updatedAt: Date = .distantPast) -> SyncFolderItem {
        return SyncFolderItem(identifier: identifier, title: title, enable: true, index: index, updatedAt: updatedAt)
    }

    private func snippet(_ identifier: String, folderId: String, title: String = "snippet", content: String = "content", index: Int = 0, updatedAt: Date = .distantPast) -> SyncSnippetItem {
        return SyncSnippetItem(identifier: identifier, folderIdentifier: folderId, title: title, content: content, enable: true, index: index, updatedAt: updatedAt)
    }

    private func payload(folders: [SyncFolderItem] = [], snippets: [SyncSnippetItem] = [], tombstones: [SyncTombstone] = []) -> SyncPayload {
        return SyncPayload(exportedAt: .distantPast, folders: folders, snippets: snippets, tombstones: tombstones)
    }

    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let earlier = Date(timeIntervalSince1970: 1_000_000)
    private let evenEarlier = Date(timeIntervalSince1970: 500_000)

    // MARK: - Tests
    @Test
    func firstExportToEmptyRemote() {
        let local = payload(folders: [folder("f1", updatedAt: now)],
                            snippets: [snippet("s1", folderId: "f1", updatedAt: now)])
        let result = SnippetSyncMerge.merge(local: local, remote: nil, state: SyncState.empty(directoryPath: "/tmp"), now: now)

        #expect(!result.localChanged)
        #expect(result.remoteChanged)
        #expect(result.payload.folders.count == 1)
        #expect(result.payload.snippets.count == 1)
    }

    @Test
    func adoptRemoteOnFreshMachine() {
        let remote = payload(folders: [folder("f1", updatedAt: earlier)],
                             snippets: [snippet("s1", folderId: "f1", updatedAt: earlier)])
        let local = payload()
        let result = SnippetSyncMerge.merge(local: local, remote: remote, state: SyncState.empty(directoryPath: "/tmp"), now: now)

        #expect(result.localChanged)
        #expect(result.payload.folders.map { $0.identifier } == ["f1"])
        #expect(result.payload.snippets.map { $0.identifier } == ["s1"])
    }

    @Test
    func unionWhenBothSidesAddedItems() {
        // Fresh state (e.g. after switching profile directory): nothing may be deleted
        let localFolder = folder("f1", updatedAt: now)
        let remoteFolder = folder("f2", updatedAt: earlier)
        let local = payload(folders: [localFolder], snippets: [snippet("s1", folderId: "f1", updatedAt: now)])
        let remote = payload(folders: [remoteFolder], snippets: [snippet("s2", folderId: "f2", updatedAt: earlier)])
        let result = SnippetSyncMerge.merge(local: local, remote: remote, state: SyncState.empty(directoryPath: "/tmp"), now: now)

        #expect(Set(result.payload.folders.map { $0.identifier }) == ["f1", "f2"])
        #expect(Set(result.payload.snippets.map { $0.identifier }) == ["s1", "s2"])
        #expect(result.localChanged)
        #expect(result.remoteChanged)
    }

    @Test
    func lastWriterWinsOnConflict() {
        let base = snippet("s1", folderId: "f1", content: "base", updatedAt: evenEarlier)
        let state = SyncState.from(payload: payload(folders: [folder("f1", updatedAt: evenEarlier)], snippets: [base]), directoryPath: "/tmp")

        let localEdit = snippet("s1", folderId: "f1", content: "local edit", updatedAt: earlier)
        let remoteEdit = snippet("s1", folderId: "f1", content: "remote edit", updatedAt: now)
        let local = payload(folders: [folder("f1", updatedAt: evenEarlier)], snippets: [localEdit])
        let remote = payload(folders: [folder("f1", updatedAt: evenEarlier)], snippets: [remoteEdit])
        let result = SnippetSyncMerge.merge(local: local, remote: remote, state: state, now: now)

        #expect(result.payload.snippets.first?.content == "remote edit")
        #expect(result.localChanged)
    }

    @Test
    func localDeletionPropagatesAsTombstone() {
        let known = snippet("s1", folderId: "f1", updatedAt: earlier)
        let folderItem = folder("f1", updatedAt: earlier)
        let state = SyncState.from(payload: payload(folders: [folderItem], snippets: [known]), directoryPath: "/tmp")

        // Locally the snippet is gone; remotely it is untouched
        let local = payload(folders: [folderItem])
        let remote = payload(folders: [folderItem], snippets: [known])
        let result = SnippetSyncMerge.merge(local: local, remote: remote, state: state, now: now)

        #expect(result.payload.snippets.isEmpty)
        #expect(result.payload.tombstones.contains { $0.identifier == "s1" && $0.kind == .snippet })
        #expect(result.remoteChanged)
        #expect(!result.localChanged)
    }

    @Test
    func remoteTombstoneDeletesUntouchedLocalItem() {
        let known = snippet("s1", folderId: "f1", updatedAt: evenEarlier)
        let folderItem = folder("f1", updatedAt: evenEarlier)
        let state = SyncState.from(payload: payload(folders: [folderItem], snippets: [known]), directoryPath: "/tmp")

        let local = payload(folders: [folderItem], snippets: [known])
        let remote = payload(folders: [folderItem], tombstones: [SyncTombstone(identifier: "s1", kind: .snippet, deletedAt: earlier)])
        let result = SnippetSyncMerge.merge(local: local, remote: remote, state: state, now: now)

        #expect(result.payload.snippets.isEmpty)
        #expect(result.localChanged)
    }

    @Test
    func localEditWinsOverOlderRemoteTombstone() {
        let folderItem = folder("f1", updatedAt: evenEarlier)
        let state = SyncState.from(payload: payload(folders: [folderItem]), directoryPath: "/tmp")

        // Edited locally now; deleted remotely earlier
        let edited = snippet("s1", folderId: "f1", content: "edited", updatedAt: now)
        let local = payload(folders: [folderItem], snippets: [edited])
        let remote = payload(folders: [folderItem], tombstones: [SyncTombstone(identifier: "s1", kind: .snippet, deletedAt: earlier)])
        let result = SnippetSyncMerge.merge(local: local, remote: remote, state: state, now: now)

        #expect(result.payload.snippets.map { $0.identifier } == ["s1"])
        #expect(!result.payload.tombstones.contains { $0.identifier == "s1" })
    }

    @Test
    func deletedFolderTakesItsSnippetsAlong() {
        let folderItem = folder("f1", updatedAt: evenEarlier)
        let member = snippet("s1", folderId: "f1", updatedAt: evenEarlier)
        let state = SyncState.from(payload: payload(folders: [folderItem], snippets: [member]), directoryPath: "/tmp")

        let local = payload(folders: [folderItem], snippets: [member])
        let remote = payload(snippets: [member], tombstones: [SyncTombstone(identifier: "f1", kind: .folder, deletedAt: earlier)])
        let result = SnippetSyncMerge.merge(local: local, remote: remote, state: state, now: now)

        #expect(result.payload.folders.isEmpty)
        #expect(result.payload.snippets.isEmpty)
        #expect(result.payload.tombstones.contains { $0.identifier == "s1" && $0.kind == .snippet })
    }

    @Test
    func convergesToNoChanges() {
        let folderItem = folder("f1", updatedAt: earlier)
        let member = snippet("s1", folderId: "f1", updatedAt: earlier)
        let bundle = payload(folders: [folderItem], snippets: [member])
        let state = SyncState.from(payload: bundle, directoryPath: "/tmp")
        let result = SnippetSyncMerge.merge(local: bundle, remote: bundle, state: state, now: now)

        #expect(!result.localChanged)
        #expect(!result.remoteChanged)
    }

    @Test
    func unionOfConflictCopiesKeepsNewestVersion() {
        let older = snippet("s1", folderId: "f1", content: "old", updatedAt: earlier)
        let newer = snippet("s1", folderId: "f1", content: "new", updatedAt: now)
        let lhs = payload(folders: [folder("f1", updatedAt: earlier)], snippets: [older, snippet("s2", folderId: "f1", updatedAt: earlier)])
        let rhs = payload(folders: [folder("f1", updatedAt: earlier)], snippets: [newer])
        let merged = SnippetSyncMerge.union(lhs, rhs, now: now)

        #expect(merged.snippets.first { $0.identifier == "s1" }?.content == "new")
        #expect(merged.snippets.contains { $0.identifier == "s2" })
    }
}

// Uses a private in-memory Realm configuration instead of mutating the global
// default configuration: suites run in parallel, and touching the shared
// default config races with the other Realm-based suites.
@MainActor
struct SnippetSyncRealmTests {

    private let configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)

    private func payload(folders: [SyncFolderItem], snippets: [SyncSnippetItem]) -> SyncPayload {
        return SyncPayload(exportedAt: Date(), folders: folders, snippets: snippets, tombstones: [])
    }

    @Test
    func applyCreatesFoldersAndOrderedSnippets() throws {
        let service = SnippetSyncService()
        let now = Date()
        let target = payload(folders: [SyncFolderItem(identifier: "f1", title: "Folder", enable: true, index: 0, updatedAt: now)],
                             snippets: [SyncSnippetItem(identifier: "s2", folderIdentifier: "f1", title: "second", content: "b", enable: true, index: 1, updatedAt: now),
                                        SyncSnippetItem(identifier: "s1", folderIdentifier: "f1", title: "first", content: "a", enable: true, index: 0, updatedAt: now)])
        try service.apply(target, configuration: configuration)

        let realm = try Realm(configuration: configuration)
        let folder = try #require(realm.object(ofType: CPYFolder.self, forPrimaryKey: "f1"))
        #expect(folder.title == "Folder")
        #expect(folder.snippets.map { $0.identifier } == ["s1", "s2"])
        #expect(folder.snippets.first?.content == "a")

        // Realm snapshot must round-trip to the same content
        let local = service.makeLocalPayload(state: SyncState.empty(directoryPath: "/tmp"), now: now, configuration: configuration)
        #expect(local.folders.map { $0.identifier } == ["f1"])
        #expect(Set(local.snippets.map { $0.identifier }) == ["s1", "s2"])
    }

    @Test
    func applyUpdatesAndDeletes() throws {
        let service = SnippetSyncService()
        let now = Date()
        try service.apply(payload(folders: [SyncFolderItem(identifier: "f1", title: "Folder", enable: true, index: 0, updatedAt: now)],
                                  snippets: [SyncSnippetItem(identifier: "s1", folderIdentifier: "f1", title: "first", content: "a", enable: true, index: 0, updatedAt: now),
                                             SyncSnippetItem(identifier: "s2", folderIdentifier: "f1", title: "second", content: "b", enable: true, index: 1, updatedAt: now)]),
                          configuration: configuration)

        // s2 deleted, s1 edited remotely
        try service.apply(payload(folders: [SyncFolderItem(identifier: "f1", title: "Renamed", enable: true, index: 0, updatedAt: now)],
                                  snippets: [SyncSnippetItem(identifier: "s1", folderIdentifier: "f1", title: "first", content: "edited", enable: true, index: 0, updatedAt: now)]),
                          configuration: configuration)

        let realm = try Realm(configuration: configuration)
        let folder = try #require(realm.object(ofType: CPYFolder.self, forPrimaryKey: "f1"))
        #expect(folder.title == "Renamed")
        #expect(folder.snippets.map { $0.identifier } == ["s1"])
        #expect(folder.snippets.first?.content == "edited")
        #expect(realm.object(ofType: CPYSnippet.self, forPrimaryKey: "s2") == nil)
    }
}

struct SnippetSyncCryptoTests {

    @Test
    func encryptDecryptRoundTrip() throws {
        let key = SnippetSyncKeyStore.StoredKey(keyId: "test-key", key: SymmetricKey(size: .bits256), isSynchronized: false)
        let payload = SyncPayload(exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                  folders: [SyncFolderItem(identifier: "f1", title: "フォルダ", enable: true, index: 0, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))],
                                  snippets: [SyncSnippetItem(identifier: "s1", folderIdentifier: "f1", title: "秘密", content: "p@ssw0rd", enable: true, index: 0, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))],
                                  tombstones: [SyncTombstone(identifier: "gone", kind: .snippet, deletedAt: Date(timeIntervalSince1970: 1_600_000_000))])

        let encrypted = try SnippetSyncCrypto.encrypt(payload, key: key)
        // Ciphertext must not leak the plaintext
        let encryptedText = String(data: encrypted, encoding: .utf8) ?? ""
        #expect(!encryptedText.isEmpty)
        #expect(!encryptedText.contains("p@ssw0rd"))

        let decrypted = try SnippetSyncCrypto.decrypt(encrypted, key: key)
        #expect(decrypted == payload)
    }

    @Test
    func decryptWithWrongKeyIdFails() throws {
        let key = SnippetSyncKeyStore.StoredKey(keyId: "key-a", key: SymmetricKey(size: .bits256), isSynchronized: false)
        let otherKey = SnippetSyncKeyStore.StoredKey(keyId: "key-b", key: key.key, isSynchronized: false)
        let encrypted = try SnippetSyncCrypto.encrypt(SyncPayload.empty(exportedAt: Date()), key: key)

        #expect(throws: SnippetSyncError.keyMismatch) {
            _ = try SnippetSyncCrypto.decrypt(encrypted, key: otherKey)
        }
    }

    @Test
    func decryptTamperedDataFails() throws {
        let key = SnippetSyncKeyStore.StoredKey(keyId: "key-a", key: SymmetricKey(size: .bits256), isSynchronized: false)
        let wrongKey = SnippetSyncKeyStore.StoredKey(keyId: "key-a", key: SymmetricKey(size: .bits256), isSynchronized: false)
        let encrypted = try SnippetSyncCrypto.encrypt(SyncPayload.empty(exportedAt: Date()), key: key)

        #expect(throws: SnippetSyncError.corruptBundle) {
            _ = try SnippetSyncCrypto.decrypt(encrypted, key: wrongKey)
        }
    }
}
