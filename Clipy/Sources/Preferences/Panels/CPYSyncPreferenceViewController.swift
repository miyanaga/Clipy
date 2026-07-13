//
//  CPYSyncPreferenceViewController.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Copyright © 2015-2026 Clipy Project.
//

import Cocoa

class CPYSyncPreferenceViewController: NSViewController {

    // MARK: - Properties
    @IBOutlet private weak var directoryTextField: NSTextField!
    @IBOutlet private weak var statusTextField: NSTextField!
    @IBOutlet private weak var keyStatusTextField: NSTextField!

    private var statusObserver: NSObjectProtocol?

    private var service: SnippetSyncService {
        return AppEnvironment.current.snippetSyncService
    }

    // MARK: - Initialize
    override func loadView() {
        super.loadView()
        refresh()
        statusObserver = NotificationCenter.default.addObserver(forName: SnippetSyncService.statusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let statusObserver = statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    // MARK: - Update
    private func refresh() {
        directoryTextField.stringValue = service.directoryPath
        statusTextField.stringValue = service.statusDescription
        switch service.keyIsSynchronized {
        case .some(true):
            keyStatusTextField.stringValue = L10n.snippetSyncKeySynced
        case .some(false):
            keyStatusTextField.stringValue = L10n.snippetSyncKeyLocalOnly
        case .none:
            keyStatusTextField.stringValue = ""
        }
    }

    // MARK: - IBActions
    @IBAction private func changeDirectoryTapped(_ sender: AnyObject) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: service.directoryPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppEnvironment.current.defaults.set(url.path, forKey: Constants.SnippetSync.directory)
        refresh()
    }

    @IBAction private func resetDirectoryTapped(_ sender: AnyObject) {
        // Fall back to the registered default (the iCloud Drive folder)
        AppEnvironment.current.defaults.removeObject(forKey: Constants.SnippetSync.directory)
        refresh()
    }

    @IBAction private func copyKeyTapped(_ sender: AnyObject) {
        do {
            let keyString = try service.exportKeyString()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            // ConcealedType keeps the key out of Clipy's own history
            pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
            pasteboard.setString(keyString, forType: .string)
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))

            let alert = NSAlert()
            alert.messageText = L10n.copySyncKey
            alert.informativeText = L10n.snippetSyncKeyCopied
            alert.runModal()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @IBAction private func importKeyTapped(_ sender: AnyObject) {
        let alert = NSAlert()
        alert.messageText = L10n.importSyncKey
        alert.informativeText = L10n.pasteTheSyncKeyCopiedFromAnotherMac
        alert.addButton(withTitle: L10n.importSyncKey)
        alert.addButton(withTitle: L10n.cancel)
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try service.importKey(from: textField.stringValue)
            refresh()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @IBAction private func syncNowTapped(_ sender: AnyObject) {
        service.requestSyncNow()
    }
}
