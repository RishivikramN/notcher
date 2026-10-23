import AppKit
import SwiftUI

/// Owns the panel for one screen and keeps it pinned to the top centre of that screen.
@MainActor
final class NotchWindowController {
    let controller: NotchController
    private let panel: NotchPanel
    private(set) var screen: NSScreen

    init(screen: NSScreen, controller: NotchController) {
        self.screen = screen
        self.controller = controller
        panel = NotchPanel(contentRect: .zero)

        let hostingView = NSHostingViewSuppressingSafeArea(rootView: NotchView(controller: controller))
        panel.contentView = hostingView
        updateFrame()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }

    func move(to screen: NSScreen) {
        self.screen = screen
        updateFrame()
    }

    /// Sized once for the largest island; transparent areas pass clicks through to whatever
    /// is underneath, so the window never needs resizing mid-animation.
    func updateFrame() {
        let width = controller.windowEnvelope.width
        let height = controller.windowEnvelope.height
        let frame = NSRect(
            x: controller.metrics.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
    }
}
