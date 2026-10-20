import Foundation

/// AMLL's documented Spotify-ID index avoids fuzzy cross-provider song matching.
public struct CommunityLyricsClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    static func url(for query: LyricsQuery) -> URL? {
        guard query.url != nil, let trackID = query.trackID else { return nil }
        let id = trackID.hasPrefix("spotify:track:") ? String(trackID.dropFirst(14)) : trackID
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard id.count == 22, id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return URL(string: "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/refs/heads/main/spotify-lyrics/\(id).lrc")
    }

    public func fetch(_ query: LyricsQuery) async throws -> LyricsDocument {
        guard let url = Self.url(for: query) else { throw LyricsLookupError.notFound }
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Futnyl/1.0 (https://github.com/adet0m1wa/futnyl)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw LyricsLookupError.invalidResponse }
        if http.statusCode == 404 { throw LyricsLookupError.notFound }
        guard http.statusCode == 200, data.count <= 1_000_000,
              let text = String(data: data, encoding: .utf8) else { throw LyricsLookupError.invalidResponse }
        let document = LyricsDocument.parse(synced: text, plain: nil, instrumental: false, source: .amll)
        guard document.hasUsableTimings(duration: query.duration) else { throw LyricsLookupError.timingUnavailable }
        return document
    }
}
