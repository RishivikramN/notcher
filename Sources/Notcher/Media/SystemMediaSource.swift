import AppKit

/// System-wide now playing through MediaRemote.
///
/// Since macOS 15.4 MediaRemote only answers Apple-signed processes, so the bundled
/// `MediaRemoteAdapter.dylib` is loaded into `/usr/bin/perl` (com.apple.perl), which streams one
/// JSON object per line, and takes playback commands on stdin. The adapter exits when Notcher
/// closes its stdin.
@MainActor
final class SystemMediaSource {
    enum Status: Equatable {
        case stopped, starting, running, unavailable(String)

        var title: String {
            switch self {
            case .stopped: "Stopped"
            case .starting: "Starting…"
            case .running: "Running"
            case .unavailable(let reason): "Unavailable: \(reason)"
            }
        }
    }

    private(set) var status: Status = .stopped {
        didSet { onStatusChange?(status) }
    }

    var onChange: ((NowPlaying?) -> Void)?
    var onStatusChange: ((Status) -> Void)?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var buffer = Data()
    private var artwork: NSImage?
    private var restartDelay: Duration = .seconds(1)
    private var isStopping = false

    private static let script = """
    use DynaLoader;
    my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die "load failed: " . DynaLoader::dl_error() . "\\n";
    my $sym = DynaLoader::dl_find_symbol($lib, $ARGV[1]) or die "symbol not found\\n";
    DynaLoader::dl_install_xsub("main::run", $sym);
    run();
    """

    static var adapterURL: URL? {
        Bundle.main.url(forResource: "MediaRemoteAdapter", withExtension: "dylib")
    }

    func start() {
        guard process == nil else { return }
        guard let adapterURL = Self.adapterURL else {
            status = .unavailable("adapter missing from the app bundle")
            return
        }
        isStopping = false
        status = .starting

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.script, adapterURL.path, "notcher_adapter_stream"]
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.consume(data) }
        }
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            Task { @MainActor in self?.processDidExit(code: code) }
        }

        do {
            try process.run()
            self.process = process
            self.stdinPipe = stdin
        } catch {
            status = .unavailable(error.localizedDescription)
        }
    }

    func stop() {
        isStopping = true
        stdinPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
        stdinPipe = nil
        status = .stopped
    }

    func perform(_ command: MediaCommand, current: NowPlaying?) {
        switch command {
        case .togglePlayPause: write("c 2")   // kMRTogglePlayPause
        case .toggleShuffle: write("c 6")     // kMRToggleShuffle (advance shuffle mode)
        case .nextTrack: write("c 4")         // kMRNextTrack
        case .previousTrack: write("c 5")     // kMRPreviousTrack
        case .seek(let seconds): write("s \(max(seconds, 0))")
        case .skip(let delta):
            guard let elapsed = current?.elapsed(at: .now) else { return }
            write("s \(max(elapsed + delta, 0))")
        }
    }

    /// Commands go to the running adapter over stdin, one per line.
    private func write(_ line: String) {
        guard let handle = stdinPipe?.fileHandleForWriting else { return }
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    // MARK: Stream

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        switch type {
        case "ready":
            status = .running
            restartDelay = .seconds(1)
        case "error":
            status = .unavailable(object["message"] as? String ?? "unknown error")
        case "nowPlaying":
            onChange?(parse(object))
        default:
            break
        }
    }

    private func parse(_ object: [String: Any]) -> NowPlaying? {
        if let base64 = object["artwork"] as? String, let data = Data(base64Encoded: base64) {
            artwork = NSImage(data: data)
        } else if object["artworkSame"] as? Bool != true {
            artwork = nil
        }

        let title = object["title"] as? String ?? ""
        guard !title.isEmpty else { return nil }

        let timestamp = (object["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .now
        return NowPlaying(
            source: .system,
            title: title,
            artist: object["artist"] as? String ?? "",
            album: object["album"] as? String ?? "",
            duration: (object["duration"] as? Double).flatMap { $0 > 0 ? $0 : nil },
            elapsed: object["elapsed"] as? Double,
            timestamp: timestamp,
            playbackRate: object["rate"] as? Double ?? 0,
            isPlaying: (object["playing"] as? Bool) ?? ((object["playing"] as? Int) == 1),
            artwork: artwork,
            bundleIdentifier: object["bundleIdentifier"] as? String,
            appName: object["appName"] as? String,
            isShuffled: (object["shuffle"] as? Int).map { $0 > 1 },
            isFallback: object["fallback"] as? Bool ?? false
        )
    }

    private func processDidExit(code: Int32) {
        process = nil
        stdinPipe = nil
        guard !isStopping else { return }
        if case .unavailable = status {} else {
            status = .unavailable("adapter exited (\(code)); restarting")
        }
        onChange?(nil)

        // Restart with backoff, capped at 30 s.
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, .seconds(30))
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !self.isStopping else { return }
            self.start()
        }
    }
}
