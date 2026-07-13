//
//  SnippetSyncCrypto.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Copyright © 2015-2026 Clipy Project.
//

import Foundation
import CryptoKit

// MARK: - Errors
enum SnippetSyncError: LocalizedError, Equatable {
    case keyNotFound
    case keyMismatch
    case keychainFailure(OSStatus)
    case corruptBundle
    case unsupportedFormat
    case invalidKeyString
    case directoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .keyNotFound: return L10n.snippetSyncWaitingForKey
        case .keyMismatch: return L10n.snippetSyncKeyMismatch
        case .keychainFailure(let status): return "Keychain error (\(status))"
        case .corruptBundle: return L10n.snippetSyncCorruptBundle
        case .unsupportedFormat: return L10n.snippetSyncUnsupportedFormat
        case .invalidKeyString: return L10n.snippetSyncInvalidKeyString
        case .directoryUnavailable(let path): return L10n.snippetSyncDirectoryUnavailable(path)
        }
    }
}

// MARK: - Envelope
// Outer plaintext JSON written to the sync directory. Only `sealed` carries
// user data (AES-GCM: nonce + ciphertext + tag).
private struct SnippetSyncEnvelope: Codable {
    static let currentFormat = "clipy-snippet-sync"
    static let currentVersion = 1

    var format: String
    var version: Int
    var keyId: String
    var sealed: Data
}

// MARK: - Crypto
enum SnippetSyncCrypto {

    static let payloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let payloadDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func encrypt(_ payload: SyncPayload, key: SnippetSyncKeyStore.StoredKey) throws -> Data {
        let plaintext = try payloadEncoder.encode(payload)
        guard let sealed = try AES.GCM.seal(plaintext, using: key.key).combined else { throw SnippetSyncError.corruptBundle }
        let envelope = SnippetSyncEnvelope(format: SnippetSyncEnvelope.currentFormat,
                                           version: SnippetSyncEnvelope.currentVersion,
                                           keyId: key.keyId,
                                           sealed: sealed)
        return try payloadEncoder.encode(envelope)
    }

    static func keyId(of data: Data) throws -> String {
        return try parseEnvelope(data).keyId
    }

    static func decrypt(_ data: Data, key: SnippetSyncKeyStore.StoredKey) throws -> SyncPayload {
        let envelope = try parseEnvelope(data)
        guard envelope.keyId == key.keyId else { throw SnippetSyncError.keyMismatch }
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealed)
            let plaintext = try AES.GCM.open(box, using: key.key)
            return try payloadDecoder.decode(SyncPayload.self, from: plaintext)
        } catch {
            throw SnippetSyncError.corruptBundle
        }
    }

    private static func parseEnvelope(_ data: Data) throws -> SnippetSyncEnvelope {
        guard let envelope = try? payloadDecoder.decode(SnippetSyncEnvelope.self, from: data) else { throw SnippetSyncError.corruptBundle }
        guard envelope.format == SnippetSyncEnvelope.currentFormat, envelope.version == SnippetSyncEnvelope.currentVersion else {
            throw SnippetSyncError.unsupportedFormat
        }
        return envelope
    }
}

// MARK: - Key Store
// Holds the AES-256 key in the Keychain. The primary location is the data
// protection keychain with kSecAttrSynchronizable, which iCloud Keychain
// replicates end-to-end encrypted to every Mac on the same Apple ID — that is
// what lets a fresh machine decrypt the bundle without any manual step. If the
// build's signature does not allow that (no provisioning), it falls back to the
// local login keychain and the key can be moved by export/import instead.
final class SnippetSyncKeyStore {

    struct StoredKey {
        let keyId: String
        let key: SymmetricKey
        let isSynchronized: Bool
    }

    static let exportPrefix = "clipy-sync-key:v1"

    private let service = "com.clipy-app.snippet-sync"
    private let account = "primary"

    private struct KeyRecord: Codable {
        var keyId: String
        var key: Data
    }

    // MARK: - Load / Create
    func load() throws -> StoredKey? {
        if let data = try copyItem(synchronizable: true) {
            return try decode(data, isSynchronized: true)
        }
        if let data = try copyItem(synchronizable: false) {
            return try decode(data, isSynchronized: false)
        }
        return nil
    }

    func loadOrCreate() throws -> StoredKey {
        if let key = try load() { return key }
        let record = KeyRecord(keyId: UUID().uuidString, key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        return try save(record)
    }

    // MARK: - Export / Import
    func exportString() throws -> String {
        guard let key = try load() else { throw SnippetSyncError.keyNotFound }
        let keyData = key.key.withUnsafeBytes { Data($0) }
        return "\(SnippetSyncKeyStore.exportPrefix):\(key.keyId):\(keyData.base64EncodedString())"
    }

    @discardableResult
    func importKey(from string: String) throws -> StoredKey {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.components(separatedBy: ":")
        let prefix = components.prefix(2).joined(separator: ":")
        guard components.count == 4,
              prefix == SnippetSyncKeyStore.exportPrefix,
              !components[2].isEmpty,
              let keyData = Data(base64Encoded: components[3]),
              keyData.count == 32 else { throw SnippetSyncError.invalidKeyString }
        return try save(KeyRecord(keyId: components[2], key: keyData))
    }

    // MARK: - Private
    private func decode(_ data: Data, isSynchronized: Bool) throws -> StoredKey {
        guard let record = try? JSONDecoder().decode(KeyRecord.self, from: data), record.key.count == 32 else {
            throw SnippetSyncError.corruptBundle
        }
        return StoredKey(keyId: record.keyId, key: SymmetricKey(data: record.key), isSynchronized: isSynchronized)
    }

    private func baseQuery(synchronizable: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if synchronizable {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        return query
    }

    private func copyItem(synchronizable: Bool) throws -> Data? {
        var query = baseQuery(synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound, errSecMissingEntitlement, errSecParam:
            return nil
        default:
            throw SnippetSyncError.keychainFailure(status)
        }
    }

    private func save(_ record: KeyRecord) throws -> StoredKey {
        let data = try JSONEncoder().encode(record)

        // Replace any existing item in both locations
        SecItemDelete(baseQuery(synchronizable: true) as CFDictionary)
        SecItemDelete(baseQuery(synchronizable: false) as CFDictionary)

        var syncedAttributes = baseQuery(synchronizable: true)
        syncedAttributes[kSecAttrSynchronizable as String] = true
        syncedAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        syncedAttributes[kSecValueData as String] = data
        if SecItemAdd(syncedAttributes as CFDictionary, nil) == errSecSuccess {
            return StoredKey(keyId: record.keyId, key: SymmetricKey(data: record.key), isSynchronized: true)
        }

        var localAttributes = baseQuery(synchronizable: false)
        localAttributes[kSecValueData as String] = data
        let status = SecItemAdd(localAttributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SnippetSyncError.keychainFailure(status) }
        return StoredKey(keyId: record.keyId, key: SymmetricKey(data: record.key), isSynchronized: false)
    }
}
