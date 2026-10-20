import AppKit

/// What Spotify is doing right now.
struct SpotifySnapshot: Equatable {
    enum State: String { case playing, paused, stopped }

    var state: State
    var trackID: String?
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var position: TimeInterval   // seconds into the track
    var duration: TimeInterval   // seconds
    /// When `position` was true, so progress can be extrapolated between updates.
    var observedAt: Date

    static let stopped = SpotifySnapshot(state: .stopped, trackID: nil, position: 0, duration: 0, observedAt: .distantPast)

    var isPlaying: Bool { state == .playing }

    /// Seconds into the track, extrapolated to `now` while playing.
    func position(at now: Date = Date()) -> TimeInterval {
        let elapsed = isPlaying ? now.timeIntervalSince(observedAt) : 0
        return min(max(position + elapsed, 0), max(duration, 0))
    }

    /// 0...1 through the current track, extrapolated to `now` while playing.
    func progress(at now: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return position(at: now) / duration
    }
}

/// Talks to the Spotify desktop app: listens to the playback notifications it
/// broadcasts, and sends it commands over AppleScript. Never launches Spotify
/// except when asked to (a key pressed while it is closed).
///
/// Spotify announces play, pause and song changes, but not seeking, nor
/// "previous" restarting a song (checked against the real app), so the
/// position is also checked four times a second.
@MainActor
final class SpotifyBridge {
    nonisolated static let bundleID = "com.spotify.client"
    private static let notification = Notification.Name("com.spotify.client.PlaybackStateChanged")

    private(set) var snapshot = SpotifySnapshot.stopped
    /// Whether the Spotify app is running (it may still be starting up).
    private(set) var isRunning = false
    /// When we last restarted the song; Spotify's next announcement can still
    /// carry the old position, which must not count.
    private var restartedAt: Date?
    /// The user declined to let Vinyl control Spotify (macOS Automation).
    private(set) var automationDenied = false

    var onChange: ((SpotifySnapshot) -> Void)?
    /// Spotify started or quit.
    var onRunningChange: ((Bool) -> Void)?
    /// The position jumped on the same song: a seek, or a restart.
    var onSeek: ((_ from: TimeInterval, _ to: TimeInterval) -> Void)?
    /// A one-line summary for the menu bar.
    var onStatusText: ((String) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var probing = false
    private var stateRevision = 0

    func start() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Self.notification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.handle(info) }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, running) in [(NSWorkspace.didLaunchApplicationNotification, true),
                                (NSWorkspace.didTerminateApplicationNotification, false)] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.bundleID else { return }
                MainActor.assumeIsolated { self?.setRunning(running) }
            })
        }
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        Task { await refresh() }
        // Compile the key commands now, so the first press is as quick as the rest.
        Task { for command in ["play", "pause", "next track", "previous track"] { await prepare(command) } }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probePosition() }
        }
    }

    private func setRunning(_ running: Bool) {
        guard running != isRunning else { return }
        isRunning = running
        onRunningChange?(running)
        // Spotify quitting does not always announce "Stopped".
        if !running { publish(.stopped) }
    }

    /// Reads the full state over AppleScript (used at launch, and to resync).
    func refresh() async {
        let script = """
            set s to player state as string
            set p to player position
            try
                set i to id of current track
                set d to duration of current track
                set n to name of current track
                set a to artist of current track
                set b to album of current track
            on error
                set i to ""
                set d to 0
                set n to ""
                set a to ""
                set b to ""
            end try
            set sep to ASCII character 31
            return s & sep & i & sep & p & sep & d & sep & n & sep & a & sep & b
        """
        let revision = stateRevision
        guard let out = await run(script), revision == stateRevision else { return }
        if out.isEmpty { publish(.stopped); return }  // Spotify is not running
        let parts = out.components(separatedBy: "\u{1f}")
        guard parts.count == 7 else { return }
        let state = SpotifySnapshot.State(rawValue: parts[0]) ?? .stopped
        publish(SpotifySnapshot(
            state: state,
            trackID: parts[1].isEmpty ? nil : parts[1],
            title: parts[4],
            artist: parts[5],
            album: parts[6],
            position: Self.number(parts[2]) ?? 0,
            duration: (Self.number(parts[3]) ?? 0) / 1000,
            observedAt: Date()))
    }

    /// Checks where the song really is: catches seeks and restarts, which
    /// Spotify does not announce.
    private func probePosition() {
        guard isRunning, !probing, snapshot.trackID != nil else { return }
        probing = true
        Task {
            defer { probing = false }
            guard let out = await run("return (id of current track) & \"|\" & (player position)"),
                  !out.isEmpty else { return }
            let parts = out.split(separator: "|").map(String.init)
            guard parts.count == 2, parts[0] == snapshot.trackID, let actual = Self.number(parts[1]) else { return }
            if let restartedAt, Date().timeIntervalSince(restartedAt) < 1.5 { return }
            let expected = snapshot.position()
            guard abs(actual - expected) > 0.8 else { return }
            var moved = snapshot
            moved.position = actual
            moved.observedAt = Date()
            onSeek?(expected, actual)
            publish(moved)
        }
    }

    /// Seek from a lyric timestamp, updating the local clock after Spotify accepts it.
    func seek(to position: TimeInterval) {
        guard isRunning, position.isFinite, let trackID = snapshot.trackID else { return }
        let clamped = min(max(position, 0), snapshot.duration)
        let value = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), clamped)
        Task {
            // The identity check runs inside Spotify too: a skip can happen while
            // this command is waiting on the serialized AppleScript queue.
            let safeID = trackID.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            guard let output = await run("if (id of current track) is \"\(safeID)\" then\nset player position to \(value)\nreturn \"ok\"\nend if"),
                  output == "ok", snapshot.trackID == trackID else { return }
            var moved = snapshot
            let from = moved.position()
            moved.position = clamped
            moved.observedAt = Date()
            onSeek?(from, clamped)
            publish(moved)
        }
    }

    // MARK: Commands

    func play() { send("play") }
    func pause() { send("pause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    /// Runs commands one after another, waiting for each.
    func perform(_ commands: [String]) async {
        for command in commands { _ = await run(command) }
    }

    /// Opens Spotify (without bringing it forward) and waits until it
    /// answers. False if it never became ready.
    func launch() async -> Bool {
        if !isRunning {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
                debugLog("launch: Spotify is not installed")
                return false
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        let started = Date()
        while Date().timeIntervalSince(started) < 20 {
            if let state = await run("return player state as string"), !state.isEmpty {
                debugLog("launch: Spotify answered after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                // Freshly started, Spotify drops a command sent too early.
                try? await Task.sleep(for: .milliseconds(300))
                return true
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        debugLog("launch: Spotify never answered")
        return false
    }

    /// We know Spotify is restarting the song (it announces nothing for that),
    /// so move our clock to the start until the next check confirms it.
    func assumeRestart() {
        restartedAt = Date()
        var restarted = snapshot
        restarted.position = 0
        restarted.observedAt = Date()
        publish(restarted)
    }

    /// The artwork URL of whatever is playing now, with the track it belongs to.
    func currentArtworkURL() async -> (trackID: String, url: URL)? {
        let out = await run("return (id of current track) & \"|\" & (artwork url of current track)")
        let parts = out?.split(separator: "|", maxSplits: 1).map(String.init) ?? []
        guard parts.count == 2, let url = URL(string: parts[1]), url.scheme?.hasPrefix("http") == true else {
            debugLog("artwork: unexpected answer \(String(describing: out))")
            return nil
        }
        return (parts[0], url)
    }

    private func prepare(_ body: String) async {
        await AppleScript.compile(script(body))
    }

    private func send(_ command: String) {
        Task { _ = await run(command) }
    }

    /// Runs `body` inside a `tell application "Spotify"` that only happens when
    /// Spotify is already running, so a query can never launch it. Answers ""
    /// when it is not running, nil when the script failed.
    private func script(_ body: String) -> String {
        """
        if application id "\(Self.bundleID)" is running then
            with timeout of 4 seconds
                tell application id "\(Self.bundleID)"
                    \(body)
                end tell
            end timeout
        end if
        return ""
        """
    }

    private func run(_ body: String) async -> String? {
        let result = await AppleScript.run(script(body))
        if result.output == nil {
            debugLog("applescript failed: \(result.error ?? "?") for: \(body.prefix(60))")
        }
        let denied = result.errorNumber == -1743
        if denied != automationDenied {
            automationDenied = denied
            onStatusText?(statusText(for: snapshot))
        }
        return result.output
    }

    // MARK: Notifications

    private func handle(_ info: [AnyHashable: Any]) {
        if !isRunning { setRunning(true) }
        let stateString = (info["Player State"] as? String ?? "").lowercased()
        let state = SpotifySnapshot.State(rawValue: stateString) ?? .stopped
        if state == .stopped {
            publish(SpotifySnapshot(state: .stopped, trackID: snapshot.trackID, title: snapshot.title, artist: snapshot.artist, album: snapshot.album, position: snapshot.position(),
                                    duration: snapshot.duration, observedAt: Date()))
            return
        }
        let duration = (info["Duration"] as? NSNumber)?.doubleValue ?? snapshot.duration * 1000
        let sameTrack = (info["Track ID"] as? String ?? snapshot.trackID) == snapshot.trackID
        var position = (info["Playback Position"] as? NSNumber)?.doubleValue ?? (sameTrack ? snapshot.position() : 0)
        if let restartedAt, Date().timeIntervalSince(restartedAt) < 2,
           info["Track ID"] as? String == snapshot.trackID, position > 3 {
            position = Date().timeIntervalSince(restartedAt)
        }
        publish(SpotifySnapshot(
            state: state,
            trackID: info["Track ID"] as? String ?? snapshot.trackID,
            title: info["Name"] as? String ?? (info["Track ID"] as? String == snapshot.trackID ? snapshot.title : ""),
            artist: info["Artist"] as? String ?? (info["Track ID"] as? String == snapshot.trackID ? snapshot.artist : ""),
            album: info["Album"] as? String ?? (info["Track ID"] as? String == snapshot.trackID ? snapshot.album : ""),
            position: position,
            duration: duration / 1000,
            observedAt: Date()))
    }

    private func publish(_ new: SpotifySnapshot) {
        stateRevision += 1
        snapshot = new
        onChange?(new)
        onStatusText?(statusText(for: new))
    }

    private func statusText(for snapshot: SpotifySnapshot) -> String {
        if automationDenied {
            return "Allow Futnyl in Settings › Privacy & Security › Automation"
        }
        guard snapshot.state != .stopped else { return "Spotify: not playing" }
        let what = [snapshot.title, snapshot.artist].filter { !$0.isEmpty }.joined(separator: " — ")
        let verb = snapshot.isPlaying ? "Playing" : "Paused"
        return what.isEmpty ? "Spotify: \(verb)" : "\(verb): \(what)"
    }

    /// AppleScript prints decimals in the user's locale ("12,5" in some regions).
    private static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}

/// Runs AppleScript in-process (about 30 ms a call, against 200 ms for a
/// separate `osascript`) on one background queue, so a slow or busy Spotify
/// never freezes the widget. Scripts run one at a time: Spotify answers
/// overlapping requests unreliably. Compiled scripts are kept for reuse.
enum AppleScript {
    private static let queue = DispatchQueue(label: "vinyl.applescript", qos: .userInitiated)
    nonisolated(unsafe) private static var compiled: [String: NSAppleScript] = [:]

    struct Result { var output: String?; var error: String?; var errorNumber: Int? }

    /// Compiles a script ahead of its first use.
    static func compile(_ source: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if compiled[source] == nil, let made = NSAppleScript(source: source) {
                    var info: NSDictionary?
                    if made.compileAndReturnError(&info) { compiled[source] = made }
                }
                continuation.resume()
            }
        }
    }

    static func run(_ source: String) async -> Result {
        let queued = Date()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            queue.async {
                var info: NSDictionary?
                let script: NSAppleScript
                if let cached = compiled[source] {
                    script = cached
                } else {
                    guard let made = NSAppleScript(source: source) else {
                        continuation.resume(returning: Result(output: nil, error: "could not create script"))
                        return
                    }
                    made.compileAndReturnError(&info)
                    if let info {
                        continuation.resume(returning: Result(output: nil, error: info.description,
                                                              errorNumber: info[NSAppleScript.errorNumber] as? Int))
                        return
                    }
                    if compiled.count > 64 { compiled.removeAll() }
                    compiled[source] = made
                    script = made
                }
                let started = Date()
                let output = script.executeAndReturnError(&info)
                let took = Date().timeIntervalSince(started), waited = started.timeIntervalSince(queued)
                if took > 0.15 || waited > 0.15 {
                    debugLog("applescript waited \(String(format: "%.2f", waited))s, ran \(String(format: "%.2f", took))s: \(source.split(separator: "\n").dropFirst(3).first?.trimmingCharacters(in: .whitespaces).prefix(50) ?? "")")
                }
                if let info {
                    continuation.resume(returning: Result(output: nil, error: info[NSAppleScript.errorMessage] as? String ?? info.description,
                                                          errorNumber: info[NSAppleScript.errorNumber] as? Int))
                    return
                }
                continuation.resume(returning: Result(output: output.stringValue ?? "", error: nil))
            }
        }
    }
}
