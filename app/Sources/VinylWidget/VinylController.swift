import AppKit
@preconcurrency import RiveRuntime

/// Keeps the Rive vinyl and Spotify in step, in both directions.
///
/// The Rive file's view model is the contract (see rive/scene.rml, "Vinyl"),
/// and the "spotify test" artboard in the same file is a dummy Spotify that
/// models everything here with the real delays; the rules match it:
/// - `isPlaying`, `progress` (0...1: the tonearm, and the record turns with
///   it, so a jump in position scrubs the record)
/// - `spotifyOpen`: while a key has asked to play but Spotify is still
///   starting, isPlaying is on and spotifyOpen off, which shows LAUNCHING
/// - `showingRecordB`: which record is on the platter. A change sets
///   `awaitingTrack` and swaps at once, so the old record leaves; the new one
///   waits off the platter until its song's cover is on it and
///   `awaitingTrack` clears. The next key does both itself.
/// - `coverA`/`coverB`, `accentColor` (the notes take the cover's colour)
/// - key triggers fired by the widget's keys (`playPressed`, ...), and
///   visual-only press triggers (`showPlayPress`, ...) the host fires so the
///   keys move when Spotify itself is used
@MainActor
final class VinylController {
    private enum Prop {
        static let isPlaying = BoolProperty(path: "isPlaying")
        static let spotifyOpen = BoolProperty(path: "spotifyOpen")
        static let showingRecordB = BoolProperty(path: "showingRecordB")
        static let awaitingTrack = BoolProperty(path: "awaitingTrack")
        static let progress = NumberProperty(path: "progress")
        static let accentColor = ColorProperty(path: "accentColor")
        static let coverA = ImageProperty(path: "coverA")
        static let coverB = ImageProperty(path: "coverB")
        static let playPressed = TriggerProperty(path: "playPressed")
        static let pausePressed = TriggerProperty(path: "pausePressed")
        static let nextPressed = TriggerProperty(path: "nextPressed")
        static let previousPressed = TriggerProperty(path: "previousPressed")
        static let showPlayPress = TriggerProperty(path: "showPlayPress")
        static let showNextPress = TriggerProperty(path: "showNextPress")
        static let showBackPress = TriggerProperty(path: "showBackPress")
    }

    /// Spotify restarts the song past 3 s; deciding a little earlier leaves
    /// room for the command to land.
    private static let backRestartsAfter: TimeInterval = 2.5
    /// A cover that has not arrived by then is skipped; the record comes in
    /// with the plain label.
    private static let coverGiveUp: TimeInterval = 2.5

    let spotify = SpotifyBridge()
    var hapticsEnabled = true

    private(set) var rive: Rive?
    private var worker: Worker?
    private var viewModel: ViewModelInstance?
    private var tasks: [Task<Void, Never>] = []

    // What the vinyl shows.
    private var showingB = false
    private var shownPlaying = false
    /// The song the vinyl stands for, and which song each record carries.
    private var appTrack: String?
    private var recordTrack: [Bool: String] = [:]
    /// Recently played track IDs, newest last, to tell "back" from "next".
    private var history: [String] = []
    /// Covers must be retained: releasing a Rive `Image` deletes it.
    private var heldCovers: [Bool: RiveRuntime.Image] = [:]
    private var art = ArtStore()

    /// A key already started the change Spotify is about to report.
    private var keyChangeAt: Date?
    private var changeID = 0
    /// Spotify is starting because a key asked it to play.
    private var launching = false
    private var launchCancelled = false
    /// When the widget's own keys last asked Spotify for something, so the
    /// echo that comes back is not mirrored as a second press.
    private var lastKeyPress: (key: String, at: Date)?
    /// Spotify has reported at least once since the widget opened.
    private var heardFromSpotify = false
    /// A "stopped" from Spotify waiting to be confirmed.
    private var pendingStop: Task<Void, Never>?
    private var lastProgress: Float = -1

    func load() async throws -> Rive {
        let worker = try await Worker(configuration: .init(enableGPUCanvas: true))
        let file = try await File(source: .local("futuristicvinyl", .main), worker: worker)
        let artboard = try await file.createArtboard("vinyl ")
        let viewModel = try await file.createViewModelInstance(.viewModelDefault(from: .artboardDefault(artboard)))
        let stateMachine = try await artboard.createStateMachine()
        try await stateMachine.bindViewModelInstances(main: viewModel)
        let rive = try await Rive(file: file, artboard: artboard, stateMachine: stateMachine,
                                  fit: .contain(alignment: .center))
        self.worker = worker
        self.viewModel = viewModel
        self.rive = rive
        observeViewModel(viewModel)
        await restoreLastPlayed()
        spotify.onChange = { [weak self] snapshot in self?.apply(snapshot) }
        spotify.onRunningChange = { [weak self] _ in self?.updateOpen() }
        spotify.onSeek = { [weak self] from, to in self?.seeked(from: from, to: to) }
        spotify.start()
        updateOpen()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateProgress() }
        }
        if ProcessInfo.processInfo.environment["VINYL_DEBUG"] == "1" {
            // What the vinyl's own script is doing, as the app sees it.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak viewModel] _ in
                Task { @MainActor in
                    guard let vm = viewModel else { return }
                    let a = (try? await vm.value(of: NumberProperty(path: "rotationPanicIsland"))) ?? -1
                    let b = (try? await vm.value(of: NumberProperty(path: "rotationFinalChampion"))) ?? -1
                    let accent = try? await vm.value(of: Prop.accentColor)
                    debugLog("script: rotation A \(Int(a))° B \(Int(b))°, accent \(String(accent?.argbValue ?? 0, radix: 16))")
                }
            }
        }
        return rive
    }

    /// Saves what is playing, so the vinyl can show it next time.
    func saveLastPlayed() {
        let snapshot = spotify.snapshot
        guard let id = appTrack, id == snapshot.trackID else { return }
        art.saveLast(LastPlayed(trackID: id, position: snapshot.position(), duration: snapshot.duration))
    }

    // MARK: Widget keys -> Spotify

    private func observeViewModel(_ vm: ViewModelInstance) {
        watch(vm.valueStream(of: Prop.showingRecordB)) { [weak self] in self?.showingB = $0 }
        watch(vm.valueStream(of: Prop.isPlaying)) { [weak self] in self?.shownPlaying = $0 }
        onTrigger(vm, Prop.playPressed) { [weak self] in self?.playPressed() }
        onTrigger(vm, Prop.pausePressed) { [weak self] in self?.pausePressed() }
        onTrigger(vm, Prop.nextPressed) { [weak self] in self?.nextPressed() }
        onTrigger(vm, Prop.previousPressed) { [weak self] in self?.backPressed() }
    }

    private func keyPressed(_ key: String) {
        debugLog("key \(key)")
        lastKeyPress = (key, Date())
        haptic()
    }

    private func pressedRecently(_ key: String, within seconds: TimeInterval = 2) -> Bool {
        guard let last = lastKeyPress else { return false }
        return last.key == key && Date().timeIntervalSince(last.at) < seconds
    }

    /// Rive already shows the press and set isPlaying.
    private func playPressed() {
        keyPressed("play")
        if spotify.isRunning, !launching {
            spotify.play()
            confirmPlaying()
        } else {
            launch(then: ["play"])
        }
    }

    private func pausePressed() {
        keyPressed("pause")
        if launching {
            launchCancelled = true  // paused before Spotify was up: just open it
            launching = false
            updateOpen()
        } else {
            spotify.pause()
        }
    }

    /// Rive already swapped the records and set awaitingTrack.
    private func nextPressed() {
        keyPressed("next")
        keyChangeAt = Date()
        watchKeyChange()
        if spotify.isRunning, !launching {
            spotify.next()
        } else {
            setPlaying(true)
            launch(then: ["next track", "play"])
        }
    }

    /// Back is decided here: early in a song Spotify goes to the previous one
    /// (swap now), later it restarts the song (the position going to 0 rewinds
    /// the record).
    private func backPressed() {
        keyPressed("back")
        guard spotify.isRunning, !launching else {
            beginChange()
            keyChangeAt = Date()
            watchKeyChange()
            setPlaying(true)
            launch(then: ["previous track", "play"])
            return
        }
        let snapshot = spotify.snapshot
        if snapshot.trackID == nil || snapshot.position() <= Self.backRestartsAfter {
            beginChange()
            keyChangeAt = Date()
            watchKeyChange()
            spotify.previous()
        } else {
            spotify.previous()
            spotify.assumeRestart()
        }
    }

    /// Starts Spotify for a key, showing LAUNCHING until it plays.
    private func launch(then commands: [String]) {
        guard !launching else { return }
        launching = true
        launchCancelled = false
        updateOpen()
        Task {
            let ok = await spotify.launch()
            if ok, !launchCancelled {
                await spotify.perform(commands)
                // LAUNCHING holds until Spotify says it is playing (see apply),
                // so the vinyl goes straight to PLAYING. Give it a while.
                for _ in 0..<40 where launching {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            guard launching else { return }
            debugLog("launch ended without playing")
            launching = false
            launchCancelled = false
            await spotify.refresh()
            setPlaying(spotify.snapshot.isPlaying)
            updateOpen()
        }
    }

    /// The play key showed playing straight away; if Spotify does not follow
    /// (nothing to play, or it failed), put the key back.
    private func confirmPlaying() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !self.launching, self.shownPlaying, !self.spotify.snapshot.isPlaying else { return }
            await self.spotify.refresh()
            guard !self.spotify.snapshot.isPlaying else { return }
            debugLog("play never confirmed; back to paused")
            self.setPlaying(false)
        }
    }

    /// A key swapped the records but Spotify reported no new song (it had
    /// nowhere to go, or restarted instead): bring the record back in with
    /// the current song.
    private func watchKeyChange() {
        let pressedAt = keyChangeAt
        Task { [weak self] in
            // Spotify can take ~2 s for the first skip after it starts (measured),
            // so allow it plenty before deciding nothing is coming.
            try? await Task.sleep(for: .seconds(self?.launching == true ? 22 : 4.5))
            guard let self, self.keyChangeAt == pressedAt, pressedAt != nil else { return }
            self.keyChangeAt = nil
            debugLog("no new song after the key; finishing the change with the current one")
            await self.spotify.refresh()
            if let id = self.spotify.snapshot.trackID {
                self.finishChange(with: id)
            } else {
                self.setAwaiting(false)
            }
        }
    }

    private func haptic() {
        guard hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    // MARK: Spotify -> widget

    private func updateOpen() {
        viewModel?.setValue(of: Prop.spotifyOpen, to: spotify.isRunning && !launching)
    }

    private func setPlaying(_ playing: Bool) {
        shownPlaying = playing
        viewModel?.setValue(of: Prop.isPlaying, to: playing)
    }

    private func setAwaiting(_ awaiting: Bool) {
        viewModel?.setValue(of: Prop.awaitingTrack, to: awaiting)
    }

    /// Starts a change from here: the old record leaves now.
    private func beginChange() {
        setAwaiting(true)
        showingB.toggle()
        viewModel?.setValue(of: Prop.showingRecordB, to: showingB)
    }

    private func apply(_ snapshot: SpotifySnapshot) {
        guard viewModel != nil else { return }
        debugLog("spotify \(snapshot.state.rawValue) \(snapshot.trackID ?? "-") \(snapshot.title) @\(Int(snapshot.position))s/\(Int(snapshot.duration))s")

        if launching, snapshot.isPlaying {
            // Spotify is up and playing: press the play key as the music starts.
            launching = false
            launchCancelled = false
            updateOpen()
            debugLog("launched; play key")
            viewModel?.fire(trigger: Prop.showPlayPress)
        }
        let songChanged = snapshot.trackID != nil && snapshot.trackID != appTrack
        if let id = snapshot.trackID, songChanged {
            trackChanged(to: id)
        }
        if snapshot.trackID != nil { heardFromSpotify = true }
        applyPlaying(snapshot.isPlaying, skipped: songChanged, stopped: snapshot.state == .stopped)
        updateProgress()
    }

    /// `skipped`: the song changed in the same update. Spotify starts playing
    /// when you skip while paused; that press already clicked, so the play key
    /// does not press (and click) a second time.
    private func applyPlaying(_ playing: Bool, skipped: Bool, stopped: Bool = false) {
        if playing {
            pendingStop?.cancel()
            pendingStop = nil
            guard !shownPlaying else { return }
            // Spotify itself resumed: press the play key like a hand would.
            let skipKey = pressedRecently("next", within: 1.5) || pressedRecently("back", within: 1.5)
            if !pressedRecently("play"), !launching, !skipped, !skipKey {
                debugLog("mirror: play key")
                viewModel?.fire(trigger: Prop.showPlayPress)
            }
            setPlaying(true)
            return
        }
        guard shownPlaying, !launching else { return }
        // A real pause shows at once. But Spotify can report "stopped" for a
        // moment while it loads the next song (seen on the first skip after it
        // starts), and quitting also begins with "stopped": wait a moment and
        // only pause if it is still not playing (or has quit).
        if stopped, spotify.isRunning {
            guard pendingStop == nil else { return }
            pendingStop = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, !Task.isCancelled else { return }
                self.pendingStop = nil
                if !self.spotify.snapshot.isPlaying, self.shownPlaying {
                    debugLog("stopped")
                    self.setPlaying(false)
                    self.saveLastPlayed()
                }
            }
            return
        }
        debugLog("paused")
        setPlaying(false)
        saveLastPlayed()
    }

    private func trackChanged(to id: String) {
        let previous = appTrack
        appTrack = id
        // The song already showing when the widget opened was never recorded;
        // without it the way back to it is mistaken for another "next".
        if history.isEmpty, let previous { history.append(previous) }
        let wentBack = history.dropLast().last == id
        if wentBack { history.removeLast() } else { history.append(id) }
        if history.count > 20 { history.removeFirst() }
        debugLog("history \(history.map { String($0.suffix(4)) }) wentBack=\(wentBack) keyChange=\(keyChangeAt != nil)")

        if keyChangeAt != nil {
            // A key already started the change.
            keyChangeAt = nil
        } else if previous == nil || !heardFromSpotify {
            // What the vinyl remembered is not what Spotify has now: change
            // records quietly, no key press.
            if previous != nil {
                beginChange()
                finishChange(with: id)
                return
            }
            // Nothing on the vinyl yet: dress the record that is showing.
            finishChange(with: id)
            return
        } else {
            // Changed in Spotify: press the matching key, unless the song
            // simply ended and Spotify played on.
            let ended = lastProgress > 0.97
            if !ended {
                debugLog("mirror: \(wentBack ? "back" : "next") key")
                viewModel?.fire(trigger: wentBack ? Prop.showBackPress : Prop.showNextPress)
            }
            beginChange()
        }
        finishChange(with: id)
    }

    /// Puts the song's cover on the record now showing, then lets it in.
    private func finishChange(with id: String) {
        let record = showingB
        recordTrack[record] = id
        lastProgress = -1
        changeID += 1
        let change = changeID
        Task {
            try? await Task.sleep(for: .seconds(Self.coverGiveUp))
            if change == self.changeID { self.setAwaiting(false) }
        }
        Task {
            let asked = Date()
            if let cover = await art.cover(for: id, spotify: spotify, worker: worker) {
                debugLog("art for \(id) took \(String(format: "%.2f", Date().timeIntervalSince(asked)))s")
                guard change == changeID else { return }
                heldCovers[record] = cover.image
                viewModel?.setValue(of: record ? Prop.coverB : Prop.coverA, to: cover.image)
                viewModel?.setValue(of: Prop.accentColor, to: cover.accent)
                debugLog("cover for \(id) on record \(record ? "B" : "A"), notes \(String(cover.accent.argbValue, radix: 16))")
                art.saveLast(LastPlayed(trackID: id, position: 0, duration: spotify.snapshot.duration))
            }
            if change == changeID { setAwaiting(false) }
        }
    }

    /// Spotify moved within the song; the record and tonearm follow (through
    /// `progress`). Back pressed in Spotify late in a song restarts it: press
    /// the vinyl's back key too.
    private func seeked(from: TimeInterval, to: TimeInterval) {
        debugLog("seek \(Int(from))s -> \(Int(to))s")
        if to < 1, from > 3, !pressedRecently("back", within: 3) {
            debugLog("restart made in Spotify; mirror: back key")
            viewModel?.fire(trigger: Prop.showBackPress)
        }
    }

    /// The tonearm and record follow the song once its record is on the platter.
    private func updateProgress() {
        let snapshot = spotify.snapshot
        // Spotify quitting reports position 0; that is not a rewind, so the
        // record stays where the song was left.
        guard snapshot.state != .stopped, spotify.isRunning else { return }
        guard let id = snapshot.trackID, recordTrack[showingB] == id else { return }
        let value = Float(snapshot.progress())
        guard abs(value - lastProgress) > 0.0002 else { return }
        lastProgress = value
        viewModel?.setValue(of: Prop.progress, to: value)
    }

    /// Shows the song played last (here or, through Spotify, on another
    /// device) where it was left, before Spotify says anything.
    private func restoreLastPlayed() async {
        guard let last = art.loadLast(), let cover = await art.lastCover(worker: worker) else { return }
        appTrack = last.trackID
        recordTrack[showingB] = last.trackID
        heldCovers[showingB] = cover.image
        viewModel?.setValue(of: showingB ? Prop.coverB : Prop.coverA, to: cover.image)
        viewModel?.setValue(of: Prop.accentColor, to: cover.accent)
        if last.duration > 0 {
            viewModel?.setValue(of: Prop.progress, to: Float(min(last.position / last.duration, 1)))
        }
        debugLog("restored last played \(last.trackID)")
    }

    // MARK: Stream helpers

    private func watch<T>(_ stream: AsyncThrowingStream<T, Error>, _ body: @escaping (T) -> Void) {
        tasks.append(Task { @MainActor in
            do { for try await value in stream { body(value) } } catch {}
        })
    }

    private func onTrigger(_ vm: ViewModelInstance, _ trigger: TriggerProperty, _ body: @escaping () -> Void) {
        tasks.append(Task { @MainActor in
            do { for try await _ in vm.stream(of: trigger) { body() } } catch {}
        })
    }
}

/// Logs only when launched with VINYL_DEBUG=1.
private let debugStart = Date()

func debugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["VINYL_DEBUG"] == "1" else { return }
    print(String(format: "[vinyl %7.3f] ", Date().timeIntervalSince(debugStart)) + message())
    fflush(stdout)
}
