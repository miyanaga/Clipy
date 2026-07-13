//
//  SnippetSyncService.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Copyright © 2015-2026 Clipy Project.
//

import Foundation
import RealmSwift
import RxSwift
import RxCocoa

/// Syncs snippets between Macs through an encrypted bundle file stored in a
/// user-visible directory (by default a folder in iCloud Drive). The local
/// Realm stays the runtime source of truth; this service reconciles it with
/// the bundle whenever either side changes. Switching the directory switches
/// the profile: merging against a fresh state never deletes local data.
final class SnippetSyncService {

    // MARK: - Types
    enum Status: Equatable {
        case disabled
        case syncing
        case waiting(String)
        case idle(Date?)
        case error(String)
    }

    static let statusDidChangeNotification = Notification.Name("kCPYSnippetSyncStatusDidChange")
    static let bundleFileName = "snippets.clipy"

    // MARK: - Properties
    private(set) var status = Status.disabled
    private(set) var keyIsSynchronized: Bool?

    private let keyStore = SnippetSyncKeyStore()
    private let syncQueue = DispatchQueue(label: "com.clipy-app.snippet-sync")
    private let disposeBag = DisposeBag()
    private var folderToken: NotificationToken?
    private var snippetToken: NotificationToken?
    private var timer: DispatchSourceTimer?
    private var debounceItem: DispatchWorkItem?
    private var directorySource: DispatchSourceFileSystemObject?

    // MARK: - Settings
    static var defaultDirectoryPath: String {
        let cloudDocs = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        #if DEBUG
            return (cloudDocs as NSString).appendingPathComponent("Clipy/Debug")
        #else
            return (cloudDocs as NSString).appendingPathComponent("Clipy")
        #endif
    }

    var isEnabled: Bool {
        return AppEnvironment.current.defaults.bool(forKey: Constants.SnippetSync.enabled)
    }

    var directoryPath: String {
        let path = AppEnvironment.current.defaults.string(forKey: Constants.SnippetSync.directory) ?? ""
        let resolved = path.isEmpty ? SnippetSyncService.defaultDirectoryPath : path
        return (resolved as NSString).expandingTildeInPath
    }

    var statusDescription: String {
        switch status {
        case .disabled: return L10n.snippetSyncDisabled
        case .syncing: return L10n.snippetSyncSyncing
        case .waiting(let message): return message
        case .idle(let date):
            guard let date = date else { return L10n.snippetSyncNever }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            return L10n.snippetSyncSyncedAt(formatter.string(from: date))
        case .error(let message): return message
        }
    }

    // MARK: - Monitoring
    func startMonitoring() {
        // Realm change notifications; the .initial event triggers the first sync after launch
        let realm = try! Realm()
        folderToken = realm.objects(CPYFolder.self)
            .observe { [weak self] _ in
                self?.scheduleSync()
            }
        snippetToken = realm.objects(CPYSnippet.self)
            .observe { [weak self] _ in
                self?.scheduleSync()
            }

        // React to settings changes
        let defaults = AppEnvironment.current.defaults
        defaults.rx.observe(Bool.self, Constants.SnippetSync.enabled, options: [.new], retainSelf: false)
            .compactMap { $0 }
            .subscribe(onNext: { [weak self] _ in
                self?.settingsDidChange()
            })
            .disposed(by: disposeBag)
        defaults.rx.observe(String.self, Constants.SnippetSync.directory, options: [.new], retainSelf: false)
            .subscribe(onNext: { [weak self] _ in
                self?.settingsDidChange()
            })
            .disposed(by: disposeBag)

        // Periodic pull for changes iCloud delivers without a directory event,
        // and retry for waiting states (key not yet synced, download pending)
        let timer = DispatchSource.makeTimerSource(queue: syncQueue)
        timer.schedule(deadline: .now() + 120, repeating: 120)
        timer.setEventHandler { [weak self] in
            self?.syncNow()
        }
        timer.resume()
        self.timer = timer

        settingsDidChange()
    }

    func requestSyncNow() {
        scheduleSync(after: 0)
    }

    // MARK: - Key Management (for preferences UI)
    func exportKeyString() throws -> String {
        _ = try keyStore.loadOrCreate()
        return try keyStore.exportString()
    }

    func importKey(from string: String) throws {
        try keyStore.importKey(from: string)
        requestSyncNow()
    }

    // MARK: - Private: Scheduling
    private func settingsDidChange() {
        DispatchQueue.main.async {
            self.stopWatchingDirectory()
            if self.isEnabled {
                self.watchDirectory()
                self.scheduleSync(after: 0.5)
            } else {
                self.setStatus(.disabled)
            }
        }
    }

    private func scheduleSync(after delay: TimeInterval = 2.0) {
        DispatchQueue.main.async {
            guard self.isEnabled else { return }
            self.debounceItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.syncQueue.async { self.syncNow() }
            }
            self.debounceItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func watchDirectory() {
        let path = directoryPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: syncQueue)
        source.setEventHandler { [weak self] in
            self?.scheduleSync()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        directorySource = source
    }

    private func stopWatchingDirectory() {
        directorySource?.cancel()
        directorySource = nil
    }

    private func setStatus(_ status: Status) {
        DispatchQueue.main.async {
            guard self.status != status else { return }
            self.status = status
            NotificationCenter.default.post(name: SnippetSyncService.statusDidChangeNotification, object: self)
        }
    }

    // MARK: - Private: Sync
    private func syncNow() {
        guard isEnabled else { return }
        setStatus(.syncing)
        do {
            try performSync()
        } catch let error as SnippetSyncError {
            if case .keyNotFound = error {
                setStatus(.waiting(L10n.snippetSyncWaitingForKey))
            } else {
                setStatus(.error(error.localizedDescription))
            }
        } catch {
            setStatus(.error(error.localizedDescription))
        }
    }

    private func performSync() throws {
        let now = Date()
        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try ensureDirectory(directoryURL)

        let bundleURL = directoryURL.appendingPathComponent(SnippetSyncService.bundleFileName)
        let fileManager = FileManager.default

        // An evicted iCloud file must not be mistaken for "no data yet"
        if !fileManager.fileExists(atPath: bundleURL.path) {
            let placeholderURL = directoryURL.appendingPathComponent(".\(SnippetSyncService.bundleFileName).icloud")
            if fileManager.fileExists(atPath: placeholderURL.path) {
                try? fileManager.startDownloadingUbiquitousItem(at: bundleURL)
                setStatus(.waiting(L10n.snippetSyncDownloading))
                return
            }
        }

        var key: SnippetSyncKeyStore.StoredKey?
        var remote: SyncPayload?
        if let remoteData = try readFile(at: bundleURL) {
            guard let existingKey = try keyStore.load() else {
                // The bundle exists but the key has not arrived via iCloud
                // Keychain yet. Creating a fresh key here would split the
                // profile, so wait (the timer retries).
                setStatus(.waiting(L10n.snippetSyncWaitingForKey))
                return
            }
            key = existingKey
            remote = try SnippetSyncCrypto.decrypt(remoteData, key: existingKey)

            // Fold iCloud conflict copies into the remote payload. Copies that
            // cannot be decrypted are left in place rather than destroyed.
            for conflictURL in conflictFileURLs(in: directoryURL, excluding: bundleURL) {
                guard let data = (try? readFile(at: conflictURL)).flatMap({ $0 }),
                      let conflictPayload = try? SnippetSyncCrypto.decrypt(data, key: existingKey) else { continue }
                remote = SnippetSyncMerge.union(remote ?? conflictPayload, conflictPayload, now: now)
                try? fileManager.removeItem(at: conflictURL)
            }
        }

        let state = loadState(for: directoryURL)
        let local = makeLocalPayload(state: state, now: now)
        let result = SnippetSyncMerge.merge(local: local, remote: remote, state: state, now: now)

        if result.localChanged {
            try apply(result.payload)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name(rawValue: Constants.Notification.closeSnippetEditor), object: nil)
            }
        }
        let payloadIsEmpty = result.payload.folders.isEmpty && result.payload.snippets.isEmpty && result.payload.tombstones.isEmpty
        if remote == nil && payloadIsEmpty {
            // Nothing to publish yet. Deliberately avoid creating a key and an
            // empty bundle: on a freshly set up Mac the real bundle (and the
            // key via iCloud Keychain) may simply not have arrived yet, and
            // racing it with a new key would split the profile.
            setStatus(.idle(now))
            return
        }
        if result.remoteChanged {
            let storedKey = try key ?? keyStore.loadOrCreate()
            key = storedKey
            let encrypted = try SnippetSyncCrypto.encrypt(result.payload, key: storedKey)
            try writeFile(encrypted, to: bundleURL)
        }
        if let storedKey = key {
            DispatchQueue.main.async { self.keyIsSynchronized = storedKey.isSynchronized }
        }
        saveState(SyncState.from(payload: result.payload, directoryPath: directoryURL.path))
        setStatus(.idle(now))

        if directorySource == nil {
            DispatchQueue.main.async { if self.isEnabled { self.watchDirectory() } }
        }
    }

    // MARK: - Realm (configuration is injectable for tests)
    func makeLocalPayload(state: SyncState, now: Date, configuration: Realm.Configuration = .defaultConfiguration) -> SyncPayload {
        let realm = try! Realm(configuration: configuration)
        var folders = [SyncFolderItem]()
        var snippets = [SyncSnippetItem]()
        for folder in realm.objects(CPYFolder.self) {
            folders.append(SyncFolderItem(identifier: folder.identifier,
                                          title: folder.title,
                                          enable: folder.enable,
                                          index: folder.index,
                                          updatedAt: .distantPast))
            for snippet in folder.snippets {
                snippets.append(SyncSnippetItem(identifier: snippet.identifier,
                                                folderIdentifier: folder.identifier,
                                                title: snippet.title,
                                                content: snippet.content,
                                                enable: snippet.enable,
                                                index: snippet.index,
                                                updatedAt: .distantPast))
            }
        }
        return SyncPayload(exportedAt: now,
                           folders: SnippetSyncMerge.attributeUpdatedAt(folders, state: state, now: now),
                           snippets: SnippetSyncMerge.attributeUpdatedAt(snippets, state: state, now: now),
                           tombstones: [])
    }

    func apply(_ payload: SyncPayload, configuration: Realm.Configuration = .defaultConfiguration) throws {
        let realm = try Realm(configuration: configuration)
        let keepFolderIds = payload.folders.map { $0.identifier }
        let keepSnippetIds = payload.snippets.map { $0.identifier }
        try realm.write {
            payload.folders.forEach { folder in
                realm.create(CPYFolder.self,
                             value: ["identifier": folder.identifier, "title": folder.title, "enable": folder.enable, "index": folder.index],
                             update: .modified)
            }
            payload.snippets.forEach { snippet in
                realm.create(CPYSnippet.self,
                             value: ["identifier": snippet.identifier, "title": snippet.title, "content": snippet.content, "enable": snippet.enable, "index": snippet.index],
                             update: .modified)
            }
            // Rebuild folder membership and ordering
            for folderItem in payload.folders {
                guard let folder = realm.object(ofType: CPYFolder.self, forPrimaryKey: folderItem.identifier) else { continue }
                let members = payload.snippets
                    .filter { $0.folderIdentifier == folderItem.identifier }
                    .sorted { $0.index < $1.index }
                    .compactMap { realm.object(ofType: CPYSnippet.self, forPrimaryKey: $0.identifier) }
                if Array(folder.snippets) != members {
                    folder.snippets.removeAll()
                    folder.snippets.append(objectsIn: members)
                }
            }
            realm.delete(realm.objects(CPYSnippet.self).filter("NOT identifier IN %@", keepSnippetIds))
            realm.delete(realm.objects(CPYFolder.self).filter("NOT identifier IN %@", keepFolderIds))
        }
    }

    // MARK: - Private: Files
    private func ensureDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return }

        // Never fabricate the iCloud Drive container: if it is missing, iCloud
        // Drive is off and a handmade folder would silently never sync.
        let cloudDocs = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if url.path.hasPrefix(cloudDocs) && !fileManager.fileExists(atPath: cloudDocs) {
            throw SnippetSyncError.directoryUnavailable(url.path)
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw SnippetSyncError.directoryUnavailable(url.path)
        }
    }

    private func readFile(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var data: Data?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { actualURL in
            data = try? Data(contentsOf: actualURL)
        }
        if coordinationError != nil { throw SnippetSyncError.corruptBundle }
        return data
    }

    private func writeFile(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { actualURL in
            do {
                try data.write(to: actualURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let error = writeError { throw error }
        if coordinationError != nil { throw SnippetSyncError.directoryUnavailable(url.deletingLastPathComponent().path) }
    }

    private func conflictFileURLs(in directoryURL: URL, excluding bundleURL: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { url in
            url.pathExtension == "clipy"
                && url.lastPathComponent.hasPrefix("snippets")
                && url.lastPathComponent != bundleURL.lastPathComponent
        }
    }

    // MARK: - Private: State
    private var stateFileURL: URL {
        return URL(fileURLWithPath: CPYUtilities.applicationSupportFolder()).appendingPathComponent("snippet-sync-state.json")
    }

    private func loadState(for directoryURL: URL) -> SyncState {
        guard let data = try? Data(contentsOf: stateFileURL),
              let state = try? SnippetSyncCrypto.payloadDecoder.decode(SyncState.self, from: data),
              state.directoryPath == directoryURL.path else {
            return SyncState.empty(directoryPath: directoryURL.path)
        }
        return state
    }

    private func saveState(_ state: SyncState) {
        guard CPYUtilities.prepareSaveToPath(CPYUtilities.applicationSupportFolder()) else { return }
        guard let data = try? SnippetSyncCrypto.payloadEncoder.encode(state) else { return }
        try? data.write(to: stateFileURL, options: .atomic)
    }
}
