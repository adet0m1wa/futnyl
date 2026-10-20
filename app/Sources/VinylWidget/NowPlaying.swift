import AppKit
import SwiftUI
import LyricsCore

@MainActor
final class NowPlayingModel: ObservableObject {
    enum LyricsState {
        case idle, loading, ready(LyricsDocument), missing, untimed, failed
    }

    @Published private(set) var snapshot = SpotifySnapshot.stopped
    @Published private(set) var lyrics: LyricsState = .idle
    @Published private(set) var spotifyRunning = false
    private var request: Task<Void, Never>?
    private var query: LyricsQuery?
    @Published private(set) var lyricsVisible = false
    private var cache: [LyricsQueryKey: LyricsDocument] = [:]
    let spotify: SpotifyBridge
    private let fetchLyrics: (LyricsQuery) async throws -> LyricsDocument

    private struct LyricsQueryKey: Hashable {
        let title: String
        let artist: String
        let album: String
        let duration: Int
        let trackID: String?
        init(_ query: LyricsQuery) {
            title = query.title; artist = query.artist; album = query.album; trackID = query.trackID
            duration = Int(min(max(query.duration.isFinite ? query.duration : 0, 0), 86400).rounded())
        }
    }

    init(spotify: SpotifyBridge,
         fetchLyrics: @escaping (LyricsQuery) async throws -> LyricsDocument = { try await LyricsClient().fetch($0) }) {
        self.spotify = spotify
        self.fetchLyrics = fetchLyrics
    }

    var title: String { snapshot.title.isEmpty ? "Nothing playing" : snapshot.title }
    var webSearchURL: URL? { query?.webSearchURL }

    func update(_ new: SpotifySnapshot) {
        spotifyRunning = spotify.isRunning
        if new.trackID == nil, !snapshot.title.isEmpty {
            // Keep the last title and lyric when Spotify quits, without advancing its clock.
            var last = snapshot
            last.position = snapshot.position()
            last.observedAt = Date()
            last.state = .stopped
            snapshot = last
        } else {
            snapshot = new
        }
        let next = LyricsQuery(title: snapshot.title, artist: snapshot.artist, duration: snapshot.duration, album: snapshot.album, trackID: snapshot.trackID)
        guard next != query else { return }
        query = next
        request?.cancel()
        lyrics = .idle
        if lyricsVisible { loadLyrics() }
    }

    func setVisible(_ visible: Bool) {
        lyricsVisible = visible
        if visible {
            if case .idle = lyrics { loadLyrics() }
        } else {
            request?.cancel()
            if case .loading = lyrics { lyrics = .idle }
        }
    }

    func loadLyrics() {
        request?.cancel()
        guard lyricsVisible, let query, query.url != nil else { lyrics = .idle; return }
        let key = LyricsQueryKey(query)
        if let cached = cache[key] { lyrics = .ready(cached); return }
        lyrics = .loading
        request = Task { [weak self] in
            do {
                let document = try await self?.fetchLyrics(query)
                guard let document else { return }
                guard let self, !Task.isCancelled, self.query == query else { return }
                if self.cache.count >= 20 { self.cache.removeAll() }
                self.cache[key] = document
                self.lyrics = .ready(document)
            } catch {
                guard let self, !Task.isCancelled, self.query == query else { return }
                switch error {
                case LyricsLookupError.notFound: self.lyrics = .missing
                case LyricsLookupError.timingUnavailable: self.lyrics = .untimed
                default: self.lyrics = .failed
                }
            }
        }
    }

    func seek(to time: TimeInterval) {
        guard spotifyRunning, snapshot.trackID == spotify.snapshot.trackID else { return }
        spotify.seek(to: time)
    }

    func togglePlayback() {
        guard spotifyRunning else { return }
        if snapshot.isPlaying { spotify.pause() } else { spotify.play() }
    }
}

/// The song header shares a row with the small disc; lyrics fill the space below.
struct InlineLyricsView: View {
    @ObservedObject var model: NowPlayingModel

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 218
            let lyricHeight = max(0, geometry.size.height - 84 * scale)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Spacer().frame(width: 78 * scale)
                    Text(model.title)
                        .font(.system(size: 13 * scale, weight: .semibold))
                        .lineLimit(2).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(model.title)
                }
                .frame(height: 72 * scale)
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    lyricsContent(position: model.snapshot.position(at: context.date), scale: scale, height: lyricHeight)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                sourceOrSearch
                    .font(.system(size: 9 * scale)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).frame(height: 12 * scale)
            }
        }
    }

    @ViewBuilder private var sourceOrSearch: some View {
        if case .ready(let document) = model.lyrics {
            Link("Lyrics: \(document.source.rawValue)", destination: document.source.url)
        } else if let url = model.webSearchURL {
            switch model.lyrics {
            case .missing, .untimed, .failed:
                Link("Find lyrics on Google ↗", destination: url)
                    .help("Search in your browser; results are not synchronized lyrics")
            default: Text("LRCLIB · AMLL")
            }
        } else {
            Text("LRCLIB · AMLL")
        }
    }

    @ViewBuilder private func lyricsContent(position: TimeInterval, scale: CGFloat, height: CGFloat) -> some View {
        switch model.lyrics {
        case .idle:
            message("Play a song in Spotify", scale: scale)
        case .loading:
            HStack(spacing: 5 * scale) {
                ProgressView().controlSize(.mini)
                Text("Finding lyrics…").font(.system(size: 10 * scale)).foregroundStyle(.secondary)
            }
        case .missing:
            VStack(alignment: .leading, spacing: 5 * scale) {
                message("No lyrics for this song", scale: scale)
                Button("Check again", action: model.loadLyrics).font(.system(size: 10 * scale)).buttonStyle(.plain)
            }
        case .untimed:
            message("No reliable timed lyrics for this recording", scale: scale)
        case .failed:
            VStack(alignment: .leading, spacing: 5 * scale) {
                message("Lyrics couldn’t load", scale: scale)
                Button("Try again", action: model.loadLyrics).font(.system(size: 10 * scale)).buttonStyle(.plain)
            }
        case .ready(let document):
            if document.instrumental {
                message("Just the music ♪", scale: scale)
            } else if !document.lines.isEmpty {
                let index = document.activeLine(at: position)
                let line = index.map { document.lines[$0] }
                ScrollView {
                    if let line, model.spotifyRunning {
                        Button { model.seek(to: line.time) } label: { lyricText(line.text, scale: scale).frame(minHeight: height) }
                            .buttonStyle(.plain).help("Replay this line")
                    } else {
                        lyricText(line?.text ?? "", scale: scale).frame(minHeight: height)
                    }
                }
                .frame(height: height)
                .defaultScrollAnchor(.center)
                .id(index ?? -1)
            } else {
                message("No reliable timed lyrics for this recording", scale: scale)
            }
        }
    }

    private func lyricText(_ text: String, scale: CGFloat) -> some View {
        Text(text.isEmpty ? "♪" : text)
            .font(.system(size: 17 * scale, weight: .medium, design: .rounded))
            .foregroundStyle(.primary).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func message(_ text: String, scale: CGFloat) -> some View {
        Text(text).font(.system(size: 12 * scale, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct LyricsToggle: View {
    @ObservedObject var model: NowPlayingModel
    let toggle: () -> Void

    var body: some View {
        GeometryReader { geometry in
            Button(action: toggle) {
                Image(systemName: model.lyricsVisible ? "opticaldisc" : "text.quote")
                    .font(.system(size: geometry.size.width * 0.52, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if model.lyricsVisible { Circle().fill(Color.primary.opacity(0.07)) }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.lyricsVisible ? "Back to turntable" : "Show lyrics")
            .accessibilityLabel(model.lyricsVisible ? "Back to turntable" : "Show lyrics")
            .accessibilityValue(model.lyricsVisible ? "On" : "Off")
        }
    }
}

/// One window and one continuously running Rive scene in both modes.
final class WidgetContentView: NSView {
    let vinylView: NSView
    let lyricsView: NSView
    let toggleView: NSView
    var lyricsMode = false {
        didSet { lyricsView.isHidden = !lyricsMode; needsLayout = true }
    }

    init(vinylView: NSView, lyricsView: NSView, toggleView: NSView) {
        self.vinylView = vinylView; self.lyricsView = lyricsView; self.toggleView = toggleView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(vinylView)
        addSubview(lyricsView)
        addSubview(toggleView)
        lyricsView.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        // Both layouts keep the same square bounds, leaving the speakers intact.
        vinylView.frame = NSRect(x: 0, y: 0, width: width, height: width)
        lyricsView.frame = WidgetLayout.lyricsFrame(width: width)
        toggleView.frame = WidgetLayout.toggleFrame(width: width, lyrics: lyricsMode)
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
