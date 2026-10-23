import AVFoundation
import SwiftUI

/// A muted, looping product render from Resources (AVPlayerLooper, as in the shipped app).
/// The renders sit on black, so `zoom` crops into the frame to make the model larger; the
/// black surround blends into the island.
struct LoopingVideoView: NSViewRepresentable {
    let resourceName: String
    var zoom: CGFloat = 1

    func makeNSView(context: Context) -> LoopingVideoNSView {
        let view = LoopingVideoNSView()
        view.load(resourceName)
        view.zoom = zoom
        return view
    }

    func updateNSView(_ view: LoopingVideoNSView, context: Context) {
        view.load(resourceName)
        view.zoom = zoom
    }

    static func dismantleNSView(_ view: LoopingVideoNSView, coordinator: ()) {
        view.stop()
    }
}

final class LoopingVideoNSView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var loadedName: String?

    var zoom: CGFloat = 1 {
        didSet { needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(_ name: String) {
        guard name != loadedName,
              let url = Bundle.main.url(forResource: name, withExtension: "mp4")
        else { return }
        loadedName = name
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        playerLayer.player = player
        self.player = player
        player.play()
    }

    func stop() {
        player?.pause()
        looper = nil
        player = nil
        playerLayer.player = nil
        loadedName = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = -bounds.width * (zoom - 1) / 2
        playerLayer.frame = bounds.insetBy(dx: inset, dy: -bounds.height * (zoom - 1) / 2)
        CATransaction.commit()
    }
}
