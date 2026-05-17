//
//  CPYDesignableView.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2016/02/25.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Foundation
import Cocoa

@IBDesignable class CPYDesignableView: NSView {

    // MARK: - Properties
    @IBInspectable var backgroundColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    @IBInspectable var borderColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    @IBInspectable var borderWidth: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    @IBInspectable var cornerRadius: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }

    // MARK: - Initialize
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    // MARK: - Appearance
    // NSColor のダイナミックカラーはアピアランスのコンテキストで解決する必要がある
    override func updateLayer() {
        let appearance = effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = backgroundColor.cgColor
            layer?.cornerRadius    = cornerRadius
            layer?.borderColor     = borderColor.cgColor
            layer?.borderWidth     = borderWidth
        }
    }

    // ライト ↔ ダーク切替時に再描画
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
