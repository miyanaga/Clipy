//
//  CPYDesignableButton.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2016/02/26.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Cocoa

class CPYDesignableButton: NSButton {

    @IBInspectable var textColor: NSColor = .labelColor {
        didSet { updateAttributedTitle() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        updateAttributedTitle()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        updateAttributedTitle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAttributedTitle()
    }

    private func updateAttributedTitle() {
        // NSColor の dynamic color はレンダリング時に appearance に合わせて解決される
        attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: textColor])
    }
}
