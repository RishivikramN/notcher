import AppKit
import SwiftUI

/// Borderless, non-activating panel that hosts the island (spec §2.1).
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        isMovable = false
        isReleasedWhenClosed = false
        canBecomeVisibleWithoutLogin = true
        animationBehavior = .none
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that lays content out into the camera housing instead of below it.
final class NSHostingViewSuppressingSafeArea<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        safeAreaRegions = []
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    /// The panel never becomes key, so the first click must reach SwiftUI directly.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
