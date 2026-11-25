import AppKit

/// Now-playing data for Apple Music and Spotify via AppleScript (public, stable).
/// macOS 15.4+ blocks third-party apps from the private MediaRemote framework,
/// so this deliberately avoids it. Browsers/other players need a different backend.
struct Snapshot: Sendable {
    enum Source: String, Sendable { case music = "Music", spotify = "Spotify" }
    var source: Source
    var title: String
    var artist: String
    var album: String
    var playing: Bool
    var position: Double
    var duration: Double
    var artworkURL: String?
}

enum Fetcher {
    static func osa(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // German/Austrian locales return "12,5" – normalise.
    private static func num(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    static func fetch(running: Set<String>) -> Snapshot? {
        var found: [Snapshot] = []
        if running.contains("com.spotify.client"), let s = spotify() { found.append(s) }
        if running.contains("com.apple.Music"), let m = music() { found.append(m) }
        return found.first(where: { $0.playing }) ?? found.first
    }

    private static func music() -> Snapshot? {
        let script = """
        tell application "Music"
          if player state is stopped then return "stopped"
          set t to current track
          return (player state as string) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & (player position as string) & "||" & ((duration of t) as string)
        end tell
        """
        guard let r = osa(script), r != "stopped" else { return nil }
        let p = r.components(separatedBy: "||")
        guard p.count == 6 else { return nil }
        return Snapshot(source: .music, title: p[1], artist: p[2], album: p[3],
                        playing: p[0] == "playing", position: num(p[4]), duration: num(p[5]),
                        artworkURL: nil)
    }

    private static func spotify() -> Snapshot? {
        let script = """
        tell application "Spotify"
          if player state is stopped then return "stopped"
          set t to current track
          return (player state as string) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & (player position as string) & "||" & ((duration of t) as string) & "||" & (artwork url of t)
        end tell
        """
        guard let r = osa(script), r != "stopped" else { return nil }
        let p = r.components(separatedBy: "||")
        guard p.count == 7 else { return nil }
        return Snapshot(source: .spotify, title: p[1], artist: p[2], album: p[3],
                        playing: p[0] == "playing", position: num(p[4]),
                        duration: num(p[5]) / 1000, artworkURL: p[6])
    }

    static func artworkData(for s: Snapshot) -> Data? {
        switch s.source {
        case .spotify:
            guard let u = s.artworkURL, let url = URL(string: u) else { return nil }
            return try? Data(contentsOf: url)
        case .music:
            let path = NSTemporaryDirectory() + "orra-art.bin"
            let script = """
            tell application "Music"
              try
                set d to raw data of artwork 1 of current track
                set f to open for access POSIX file "\(path)" with write permission
                set eof f to 0
                write d to f
                close access f
                return "ok"
              on error
                try
                  close access POSIX file "\(path)"
                end try
                return "err"
              end try
            end tell
            """
            guard osa(script) == "ok" else { return nil }
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
    }
}

@MainActor
final class NowPlayingModel: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var artwork: NSImage?
    @Published var isPlaying = false
    @Published var duration: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var positionStamp = Date()

    private(set) var source: Snapshot.Source?
    var isScrubbing = false
    private var ignoreStateUntil = Date.distantPast
    private var positionLockUntil = Date.distantPast   // ignore stale polls right after a seek
    private var lastKey = ""
    private var polling = false
    private var timer: Timer?

    var hasTrack: Bool { !title.isEmpty }

    /// Creator line: artist for songs; for podcasts the host/creator, else the show name.
    var creator: String {
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.isEmpty { return a }
        return album.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func currentPosition(at date: Date) -> Double {
        let p = position + (isPlaying ? date.timeIntervalSince(positionStamp) : 0)
        return duration > 0 ? min(p, duration) : p
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func poll() {
        guard !polling else { return }
        polling = true
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        Task.detached(priority: .utility) {
            let snap = Fetcher.fetch(running: running)
            await MainActor.run { self.apply(snap) }
        }
    }

    private func apply(_ s: Snapshot?) {
        polling = false
        guard let s else {
            title = ""; artist = ""; album = ""; artwork = nil; isPlaying = false
            source = nil; lastKey = ""
            return
        }
        source = s.source
        title = s.title; artist = s.artist; album = s.album
        if Date() > ignoreStateUntil { isPlaying = s.playing }
        duration = s.duration
        if !isScrubbing && Date() > positionLockUntil { position = s.position; positionStamp = Date() }

        let key = "\(s.source.rawValue)|\(s.title)|\(s.artist)"
        if key != lastKey {
            lastKey = key
            artwork = nil
            Task.detached(priority: .utility) {
                let data = Fetcher.artworkData(for: s)
                await MainActor.run {
                    if self.lastKey == key, let data, let img = NSImage(data: data) {
                        self.artwork = img
                    }
                }
            }
        }
    }

    // MARK: Controls
    func seek(to t: Double) {
        guard let src = source, duration > 0 else { return }
        let target = max(0, min(t, duration - 1))
        position = target; positionStamp = Date()      // optimistic update
        isScrubbing = true
        positionLockUntil = .distantFuture             // drop any poll that started before the seek
        Task.detached(priority: .userInitiated) {
            let r = Fetcher.osa("tell application \"\(src.rawValue)\" to set player position to \(Int(target))")
            lpLog("seek \(src.rawValue) to \(Int(target)) -> \(r ?? "FAILED")")
            await MainActor.run {
                self.isScrubbing = false
                // players report the new position slightly late; keep our value, then resync
                self.positionLockUntil = Date().addingTimeInterval(1.2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { self.poll() }
            }
        }
    }

    func playPause() {
        // freeze/unfreeze the progress clock and flip the icon immediately
        position = currentPosition(at: Date()); positionStamp = Date()
        isPlaying.toggle()
        ignoreStateUntil = Date().addingTimeInterval(1.5)
        command("playpause")
    }
    func next()      { command("next track") }
    func previous()  { command("previous track") }

    private func command(_ c: String) {
        guard let src = source else { return }
        Task.detached(priority: .userInitiated) {
            _ = Fetcher.osa("tell application \"\(src.rawValue)\" to \(c)")
            await MainActor.run { self.poll() }
        }
    }
}
