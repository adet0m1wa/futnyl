import XCTest
@testable import LyricsCore

/// Opt-in integration checks against public fixtures, never the user's playback.
final class LiveLyricsTests: XCTestCase {
    func testCommunityPublicRecordingHasValidatedTimings() async throws {
        guard ProcessInfo.processInfo.environment["FUTNYL_LIVE_LYRICS_TESTS"] == "1" else {
            throw XCTSkip("Set FUTNYL_LIVE_LYRICS_TESTS=1 to check public sample recordings")
        }
        let query = LyricsQuery(title: "Never Gonna Give You Up", artist: "Rick Astley", duration: 213,
                                trackID: "spotify:track:4PTG3Z6ehGkBFwjybzWkR8")
        let document = try await CommunityLyricsClient().fetch(query)
        XCTAssertEqual(document.source, .amll)
        XCTAssertTrue(document.hasUsableTimings(duration: query.duration))
        print("Public AMLL fixture: \(document.lines.count) timed lines")
    }

    func testPublicRecordingsHaveValidatedTimings() async throws {
        guard ProcessInfo.processInfo.environment["FUTNYL_LIVE_LYRICS_TESTS"] == "1" else {
            throw XCTSkip("Set FUTNYL_LIVE_LYRICS_TESTS=1 to check public sample recordings")
        }
        let samples: [LyricsQuery] = [
            .init(title: "Never Gonna Give You Up", artist: "Rick Astley", duration: 213),
            .init(title: "Blinding Lights", artist: "The Weeknd", duration: 200, album: "After Hours"),
            .init(title: "Bohemian Rhapsody", artist: "Queen", duration: 354),
            .init(title: "Not Like Us", artist: "Kendrick Lamar", duration: 274),
        ]
        for query in samples {
            let document = try await LyricsClient().fetch(query)
            XCTAssertTrue(document.hasUsableTimings(duration: query.duration))
            let first = try XCTUnwrap(document.lines.first(where: { !$0.text.isEmpty }))
            let last = try XCTUnwrap(document.lines.last(where: { !$0.text.isEmpty }))
            XCTAssertEqual(document.activeLine(at: last.time), last.id)
            XCTAssertEqual(document.activeLine(at: first.time), first.id)
            print("Public lyric fixture: \(query.title), \(document.lines.count) timed lines")
        }
    }
}
