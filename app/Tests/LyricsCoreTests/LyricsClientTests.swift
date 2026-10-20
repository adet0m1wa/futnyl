import Foundation
import XCTest
@testable import LyricsCore

private final class LyricsURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]
    nonisolated(unsafe) static var requested: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requested.append(request.url!)
        let (status, body) = Self.responses[request.url!.path] ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LyricsClientTests: XCTestCase {
    private let query = LyricsQuery(title: "A + B", artist: "Artist", duration: 200)

    private func record(title: String = "A + B", artist: String = "Artist", album: String = "Album", duration: Double = 200,
                        synced: String? = "[00:01] One line\n[00:10] Another line", instrumental: Bool = false) -> [String: Any] {
        ["trackName": title, "artistName": artist, "albumName": album, "duration": duration,
         "syncedLyrics": synced as Any? ?? NSNull(), "plainLyrics": "One line\nAnother line", "instrumental": instrumental]
    }

    private func client(status: Int = 200, exact: [String: Any]? = nil, search: [[String: Any]] = [], community: String? = nil) -> LyricsClient {
        LyricsURLProtocol.requested = []
        LyricsURLProtocol.responses = [
            "/api/get": (status, try! JSONSerialization.data(withJSONObject: exact ?? [:])),
            "/api/search": (200, try! JSONSerialization.data(withJSONObject: search)),
        ]
        if let community {
            LyricsURLProtocol.responses["/amll-dev/amll-ttml-db/refs/heads/main/spotify-lyrics/0123456789ABCDEFGHIJKL.lrc"] = (200, Data(community.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsURLProtocol.self]
        return LyricsClient(session: URLSession(configuration: config))
    }

    func testSuccessfulSyncedResponse() async throws {
        let result = try await client(exact: record()).fetch(query)
        XCTAssertEqual(result.lines.first?.text, "One line")
        XCTAssertEqual(result.lines.first?.time, 1)
        XCTAssertEqual(LyricsURLProtocol.requested.count, 1)
        XCTAssertTrue(query.url!.absoluteString.contains("%2B"))
    }

    func testInstrumentalWithoutTimedTextIsSuccessful() async throws {
        let result = try await client(exact: record(synced: nil, instrumental: true)).fetch(query)
        XCTAssertTrue(result.instrumental)
    }

    func testMissingRecordingIsNotFound() async {
        do {
            _ = try await client(status: 404).fetch(query)
            XCTFail("Expected missing lyrics")
        } catch LyricsLookupError.notFound {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testSingleZeroTimestampFallsBackToProperTimedRecording() async throws {
        let result = try await client(exact: record(synced: "[00:00] Pasted plain text"), search: [record()]).fetch(query)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines.last?.time, 10)
        XCTAssertEqual(LyricsURLProtocol.requested.map(\.path), ["/api/get", "/api/search"])
    }

    func test404FallsBackAndRejectsWrongVersionBeforeMatching() async throws {
        let result = try await client(status: 404, search: [record(title: "A + B - Live"), record(artist: "Other Artist"), record(duration: 220), record()]).fetch(query)
        XCTAssertEqual(result.lines.count, 2)
    }

    func testWrongArtistTitleAlbumAndDurationNeverSupplyLyrics() async {
        let specific = LyricsQuery(title: query.title, artist: query.artist, duration: query.duration, album: "Album")
        let candidates = [record(title: "A + B - Remix"), record(artist: "Other Artist"), record(album: "Different Edition"), record(duration: 203)]
        do {
            _ = try await client(exact: candidates[0], search: candidates).fetch(specific)
            XCTFail("A different recording must not match")
        } catch LyricsLookupError.notFound {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testUntimedOrBeyondTrackTimestampsAreNotPresentedAsSynced() async {
        for candidate in [record(synced: nil), record(synced: "[00:00] All at zero"), record(synced: "[00:01] First\n[05:00] Too late")] {
            do {
                _ = try await client(exact: candidate).fetch(query)
                XCTFail("Expected unusable timing")
            } catch LyricsLookupError.timingUnavailable {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testSearchPrefersClosestMatchingDuration() async throws {
        let result = try await client(status: 404, search: [record(duration: 202, synced: "[00:01] Less close\n[00:12] Last"), record(duration: 200, synced: "[00:01] Exact duration\n[00:10] Last")]).fetch(query)
        XCTAssertEqual(result.lines.first?.text, "Exact duration")
    }

    func testCaseAndPunctuationNormalization() async throws {
        let result = try await client(exact: record(title: "a + b", artist: "ARTIST")).fetch(query)
        XCTAssertEqual(result.lines.count, 2)
    }

    func testServerErrorDoesNotTriggerSearch() async {
        do {
            _ = try await client(status: 503).fetch(query)
            XCTFail("Expected service error")
        } catch LyricsLookupError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(LyricsURLProtocol.requested.count, 1)
    }

    private var identifiedQuery: LyricsQuery {
        .init(title: query.title, artist: query.artist, duration: query.duration, trackID: "spotify:track:0123456789ABCDEFGHIJKL")
    }

    func testProviderOrderPrefersLRCLIBWithoutCallingCommunity() async throws {
        let result = try await client(exact: record(), community: "[00:01] Community\n[00:10] Last").fetch(identifiedQuery)
        XCTAssertEqual(result.source, .lrclib)
        XCTAssertEqual(LyricsURLProtocol.requested.count, 1)
    }

    func testMissingLRCLIBFallsBackToCommunityByExactSpotifyID() async throws {
        let result = try await client(status: 404, community: "[00:01] Community\n[00:10] Last").fetch(identifiedQuery)
        XCTAssertEqual(result.source, .amll)
        XCTAssertEqual(result.activeLine(at: 5), 0)
        XCTAssertEqual(result.activeLine(at: 11), 1)
        XCTAssertEqual(LyricsURLProtocol.requested.map(\.host), ["lrclib.net", "lrclib.net", "raw.githubusercontent.com"])
    }

    func testCommunityCanRecoverFromPrimaryOutageOrUntimedRecord() async throws {
        for (status, exact) in [(503, record()), (200, record(synced: "[00:00] Untimed"))] {
            let result = try await client(status: status, exact: exact, community: "[00:01] First\n[00:10] Last").fetch(identifiedQuery)
            XCTAssertEqual(result.source, .amll)
        }
    }

    func testCommunityRejectsUntimedAndBeyondRecordingLines() async {
        for text in ["[00:00] Untimed", "[00:01] First\n[10:00] Wrong duration", "Plain text only"] {
            do {
                _ = try await client(status: 404, community: text).fetch(identifiedQuery)
                XCTFail("Must reject unusable community timestamps")
            } catch LyricsLookupError.timingUnavailable {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testInvalidOrLocalSpotifyIDsNeverCreateCommunityRequests() {
        for id in ["spotify:local:artist:album:title:200", "../../private", "https://example.com/track", "", "0123456789ABCDEFGHIJK/"] {
            XCTAssertNil(CommunityLyricsClient.url(for: .init(title: "Song", artist: "Artist", duration: 200, trackID: id)))
        }
        XCTAssertNotNil(CommunityLyricsClient.url(for: identifiedQuery))
    }

    func testCancelledLookupDoesNotStartAnotherProvider() async {
        let service = client(status: 404, community: "[00:01] First\n[00:10] Last")
        let query = identifiedQuery
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.fetch(query)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(LyricsURLProtocol.requested.isEmpty)
    }

    func testGoogleIsOnlyAnEscapedDiscoveryURL() {
        let url = query.webSearchURL!
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "A + B Artist lyrics")
    }
}
