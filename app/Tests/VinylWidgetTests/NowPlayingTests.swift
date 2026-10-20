import AppKit
import SwiftUI
import XCTest
import LyricsCore
@testable import VinylWidget

@MainActor
final class NowPlayingTests: XCTestCase {
    private func song(_ title: String, position: Double = 0, state: SpotifySnapshot.State = .playing) -> SpotifySnapshot {
        SpotifySnapshot(state: state, trackID: title, title: title, artist: "Artist", position: position, duration: 200, observedAt: Date())
    }

    func testLyricsOffMakesNoRequestsAndToggleUsesCache() async {
        var calls = 0
        let loaded = expectation(description: "Lyrics fetched")
        let model = NowPlayingModel(spotify: SpotifyBridge()) { _ in
            calls += 1
            loaded.fulfill()
            return LyricsDocument.parse(synced: "[00:01] Line", plain: nil, instrumental: false)
        }
        model.update(song("Song"))
        await Task.yield()
        XCTAssertEqual(calls, 0)
        model.setVisible(true)
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(calls, 1)
        guard case .ready = model.lyrics else { return XCTFail("Lyrics should load") }
        model.setVisible(false)
        model.setVisible(true)
        XCTAssertEqual(calls, 1)
    }

    func testLateResponseCannotReplaceNewSong() async {
        var pending: [String: CheckedContinuation<LyricsDocument, Never>] = [:]
        let firstRequested = expectation(description: "First request started")
        let secondRequested = expectation(description: "Second request started")
        let firstReturned = expectation(description: "Cancelled request returned")
        let secondReturned = expectation(description: "Current request returned")
        let model = NowPlayingModel(spotify: SpotifyBridge()) { query in
            let document = await withCheckedContinuation { pending[query.title] = $0
                if query.title == "First" { firstRequested.fulfill() } else { secondRequested.fulfill() }
            }
            if query.title == "First" { firstReturned.fulfill() } else { secondReturned.fulfill() }
            return document
        }
        model.update(song("First"))
        model.setVisible(true)
        await fulfillment(of: [firstRequested], timeout: 2)
        model.update(song("Second"))
        await fulfillment(of: [secondRequested], timeout: 2)
        pending["Second"]?.resume(returning: .parse(synced: "[00:01] Second line", plain: nil, instrumental: false))
        await fulfillment(of: [secondReturned], timeout: 2)
        pending["First"]?.resume(returning: .parse(synced: "[00:01] First line", plain: nil, instrumental: false))
        await fulfillment(of: [firstReturned], timeout: 2)
        guard case .ready(let doc) = model.lyrics else { return XCTFail("Second lyrics should remain ready") }
        XCTAssertEqual(doc.lines.first?.text, "Second line")
        XCTAssertEqual(model.title, "Second")
    }

    func testPlaybackClockKeepsLyricsOnPauseAndSeek() {
        let observed = Date(timeIntervalSince1970: 1000)
        var snapshot = SpotifySnapshot(state: .playing, trackID: "Track", title: "Song", artist: "Artist", position: 10, duration: 200, observedAt: observed)
        let document = LyricsDocument.parse(synced: "[00:02] First\n[00:12] Second", plain: nil, instrumental: false)
        XCTAssertEqual(document.activeLine(at: snapshot.position(at: observed.addingTimeInterval(5))), 1)
        snapshot.position = 15
        snapshot.observedAt = observed.addingTimeInterval(5)
        snapshot.state = .paused
        XCTAssertEqual(document.activeLine(at: snapshot.position(at: observed.addingTimeInterval(100))), 1)
        snapshot.position = 3
        XCTAssertEqual(document.activeLine(at: snapshot.position(at: observed.addingTimeInterval(100))), 0)
    }

    func testUnusableTimingsShowUnavailableAndAlbumIsIncludedInLookup() async {
        let requested = expectation(description: "Recording lookup")
        let model = NowPlayingModel(spotify: SpotifyBridge()) { query in
            XCTAssertEqual(query.album, "Recording edition")
            requested.fulfill()
            throw LyricsLookupError.timingUnavailable
        }
        var recording = song("Song")
        recording.album = "Recording edition"
        model.update(recording)
        model.setVisible(true)
        await fulfillment(of: [requested], timeout: 2)
        guard case .untimed = model.lyrics else {
            return XCTFail("Invalid timing must produce an unavailable state")
        }
    }

    func testQuitPreservesTitleAndFreezesPosition() {
        let model = NowPlayingModel(spotify: SpotifyBridge())
        model.update(song("Remember me", position: 25))
        model.update(.stopped)
        XCTAssertEqual(model.title, "Remember me")
        XCTAssertFalse(model.snapshot.isPlaying)
        XCTAssertEqual(model.snapshot.position(at: Date().addingTimeInterval(100)), model.snapshot.position, accuracy: 0.01)
    }

    func testRenderIntegratedWidgetInBothAppearances() async throws {
        let loaded = expectation(description: "Lyrics fetched")
        let model = NowPlayingModel(spotify: SpotifyBridge()) { _ in
            loaded.fulfill()
            return .parse(synced: "[00:01] Let the music find its way home", plain: nil, instrumental: false)
        }
        model.update(song("A song for the evening (a very long version)", position: 2, state: .paused))
        model.setVisible(true)
        await fulfillment(of: [loaded], timeout: 2)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FutnylPreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            for compact in [false, true] {
                let mode = compact ? "lyrics" : "normal"
                let scene = NSImageView()
                if let previews = ProcessInfo.processInfo.environment["FUTNYL_PREVIEW_SCENE_DIR"] {
                    scene.image = try XCTUnwrap(NSImage(contentsOfFile: "\(previews)/\(mode)-\(name).png"))
                    scene.imageScaling = .scaleAxesIndependently
                }
                let lyrics = FirstMouseHostingView(rootView: InlineLyricsView(model: model).environment(\.colorScheme, scheme))
                let toggle = FirstMouseHostingView(rootView: LyricsToggle(model: model, toggle: {}).environment(\.colorScheme, scheme))
                let view = WidgetContentView(vinylView: scene, lyricsView: lyrics, toggleView: toggle)
                view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                model.setVisible(compact)
                view.lyricsMode = compact
                view.setFrameSize(WidgetLayout.windowSize(width: 270, lyrics: compact))
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("widget-\(mode)-\(name).png"))
                XCTAssertGreaterThan(png.count, 100)
                XCTAssertTrue(toggle.acceptsFirstMouse(for: nil))
            }
        }
        print("Widget previews: \(folder.path)")
    }

    func testBothLayoutsStayInsideOneWidgetAtEverySize() {
        let vinyl = NSView()
        let lyrics = NSView()
        let toggle = NSView()
        let content = WidgetContentView(vinylView: vinyl, lyricsView: lyrics, toggleView: toggle)
        for width in [200.0, 270.0, 360.0, 480.0] {
            for compact in [false, true, false] {
                content.lyricsMode = compact
                content.setFrameSize(WidgetLayout.windowSize(width: width, lyrics: compact))
                content.layoutSubtreeIfNeeded()
                XCTAssertTrue(content.vinylView === vinyl)
                XCTAssertEqual(content.subviews.count, 3)
                XCTAssertEqual(vinyl.frame.size, NSSize(width: width, height: width))
                XCTAssertEqual(vinyl.frame.maxY, content.bounds.maxY)
                XCTAssertEqual(lyrics.isHidden, !compact)
                XCTAssertTrue(content.bounds.contains(toggle.frame))
                let toggleCentre = NSPoint(x: toggle.frame.midX, y: toggle.frame.midY)
                XCTAssertTrue(content.hitTest(toggleCentre) === toggle)
                if compact {
                    XCTAssertTrue(content.bounds.contains(lyrics.frame))
                    XCTAssertEqual(content.frame.height, width)
                    XCTAssertEqual(toggle.frame.width, 40 * width / 270, accuracy: 0.001)
                    let lyricCentre = NSPoint(x: lyrics.frame.midX, y: lyrics.frame.midY)
                    XCTAssertTrue(content.hitTest(lyricCentre) === lyrics)
                } else {
                    XCTAssertEqual(content.frame.height, width)
                    XCTAssertEqual(vinyl.frame.origin, .zero)
                }
            }
        }
    }

    func testLyricsModePreservesBodyAndSpeakerGeometry() {
        let full = Dictionary(uniqueKeysWithValues: WidgetLayout.sceneValues(lyrics: false))
        let lyrics = Dictionary(uniqueKeysWithValues: WidgetLayout.sceneValues(lyrics: true))
        for property in ["controlsY", "bodyHeight", "bodyY", "speakerY", "speakerWellY"] {
            XCTAssertEqual(lyrics[property], full[property], "The speaker/body bounds must stay unchanged")
        }
        XCTAssertEqual(WidgetLayout.windowSize(width: 270, lyrics: true), WidgetLayout.windowSize(width: 270, lyrics: false))
    }

    func testSongTitleLabelFitsAndPreservesUnicodeCharacters() {
        XCTAssertEqual(WidgetLayout.titleLabel(for: "Short title"), "Short title")
        XCTAssertEqual(WidgetLayout.titleLabel(for: ""), "Nothing playing")
        let long = "A very long title with many more words"
        XCTAssertEqual(WidgetLayout.titleLabel(for: long).count, 19)
        XCTAssertTrue(WidgetLayout.titleLabel(for: long).hasSuffix("…"))
        let unicode = String(repeating: "é", count: 30)
        XCTAssertEqual(WidgetLayout.titleLabel(for: unicode), String(repeating: "é", count: 18) + "…")
    }
}
