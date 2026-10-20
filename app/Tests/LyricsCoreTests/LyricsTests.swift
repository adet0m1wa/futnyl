import XCTest
@testable import LyricsCore

final class LyricsTests: XCTestCase {
    func testRepeatedTimestampsFractionsAndStableSorting() {
        let doc = LyricsDocument.parse(synced: "[ar:Artist]\r\n[01:02.345][00:01.2] Chorus\r\n[00:01.20] Echo", plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines.map(\.time), [1.2, 1.2, 62.345])
        XCTAssertEqual(doc.lines.map(\.text), ["Chorus", "Echo", "Chorus"])
        XCTAssertEqual(doc.lines.map(\.id), [0, 1, 2])
    }

    func testInvalidTimestampsAndMetadataAreIgnored() {
        let doc = LyricsDocument.parse(synced: "[ti:Song]\n[00:99] Bad\n[-1:00] Bad\n[0:02.1234] Bad\n[00:03] Fine", plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines.map(\.text), ["Fine"])
    }

    func testOffsetAndBlankInstrumentalGap() {
        let doc = LyricsDocument.parse(synced: "[offset:-500]\n[00:00.2] Start\n[00:02.00]\n[00:04.00] End", plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines.map(\.time), [0, 1.5, 3.5])
        XCTAssertEqual(doc.lines[1].text, "")
        XCTAssertEqual(doc.activeLine(at: 2), 1)
    }

    func testPositionBoundariesPauseAndSeekBack() {
        let doc = LyricsDocument.parse(synced: "[00:02] First\n[00:05] Second", plain: nil, instrumental: false)
        XCTAssertNil(doc.activeLine(at: 0))
        XCTAssertEqual(doc.activeLine(at: 2), 0)
        XCTAssertEqual(doc.activeLine(at: 4.99), 0)
        XCTAssertEqual(doc.activeLine(at: 5), 1)
        XCTAssertEqual(doc.activeLine(at: 500), 1)
        XCTAssertEqual(doc.activeLine(at: 3), 0)
        XCTAssertEqual(doc.activeLine(at: 3), 0)
    }

    func testPlainFallbackAndInstrumental() {
        let doc = LyricsDocument.parse(synced: "[ar:Artist]", plain: "  First\nSecond\n ", instrumental: false)
        XCTAssertTrue(doc.lines.isEmpty)
        XCTAssertEqual(doc.plainText, "First\nSecond")
        let empty = LyricsDocument.parse(synced: nil, plain: " \n", instrumental: true)
        XCTAssertNil(empty.plainText)
        XCTAssertTrue(empty.instrumental)
    }

    func testTimestampInsideLyricTextIsNotAnotherLine() {
        let doc = LyricsDocument.parse(synced: "[00:02] Meet me at [12:34]", plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines.count, 1)
        XCTAssertEqual(doc.lines.first?.text, "Meet me at [12:34]")
    }

    func testAlbumAndExactDurationAreIncludedInLookup() throws {
        let query = LyricsQuery(title: "Song", artist: "Artist", duration: 286.767, album: "The Album")
        let url = try XCTUnwrap(query.url)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "album_name" })?.value, "The Album")
        XCTAssertEqual(items.first(where: { $0.name == "duration" })?.value, "286.767")
    }

    func testSingleTimestampAndPlainTextDoNotPassTimingValidation() {
        for synced in [nil, "[00:00] One long line", "[00:00] First\n[00:00] Second", "[00:01] First\n[10:00] Beyond track"] {
            XCTAssertFalse(LyricsDocument.parse(synced: synced, plain: "Text", instrumental: false).hasUsableTimings(duration: 200))
        }
        XCTAssertTrue(LyricsDocument.parse(synced: "[00:01] First\n[00:10] Second", plain: nil, instrumental: false).hasUsableTimings(duration: 200))
    }

    func testPositiveOffset() {
        let doc = LyricsDocument.parse(synced: "[offset:+250]\n[00:01] Word", plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines.first?.time, 1.25)
    }

    func testQueryEscapesUnicodeAndSeparators() throws {
        let query = LyricsQuery(title: "L'été & You? #1", artist: "A/B + C", duration: 202.6)
        let url = try XCTUnwrap(query.url)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "https")
        XCTAssertEqual(parts.host, "lrclib.net")
        XCTAssertEqual(parts.path, "/api/get")
        let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["track_name"], query.title)
        XCTAssertEqual(items["artist_name"], query.artist)
        XCTAssertEqual(items["duration"], "202.600")
    }

    func testInvalidQueriesDoNotGenerateRequests() {
        for duration in [Double.nan, .infinity, -.infinity, 0, -1, 3601] {
            XCTAssertNil(LyricsQuery(title: "Song", artist: "Artist", duration: duration).url)
        }
        XCTAssertNil(LyricsQuery(title: " ", artist: "Artist", duration: 200).url)
        XCTAssertNil(LyricsQuery(title: "Song", artist: "\n", duration: 200).url)
    }
}
