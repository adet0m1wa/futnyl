import Foundation

public enum LyricsSource: String, Sendable {
    case lrclib = "LRCLIB"
    case amll = "AMLL"

    public var url: URL {
        switch self {
        case .lrclib: return URL(string: "https://lrclib.net")!
        case .amll: return URL(string: "https://github.com/amll-dev/amll-ttml-db")!
        }
    }
}

public struct LyricLine: Identifiable, Equatable, Sendable {
    public let id: Int
    public let time: TimeInterval
    public let text: String
}

public struct LyricsDocument: Equatable, Sendable {
    public let lines: [LyricLine]
    public let plainText: String?
    public let instrumental: Bool
    public let source: LyricsSource

    public static func parse(synced: String?, plain: String?, instrumental: Bool, source: LyricsSource = .lrclib) -> Self {
        let timestamp = try! NSRegularExpression(pattern: #"\[(\d+):([0-5]\d(?:\.\d{1,3})?)\]"#)
        let offsetPattern = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#)
        let timedText = synced ?? ""
        let ns = timedText as NSString
        let offset = offsetPattern.firstMatch(in: timedText, range: NSRange(location: 0, length: ns.length))
            .flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        var entries: [(time: Double, text: String, order: Int)] = []
        for row in timedText.components(separatedBy: .newlines) {
            let text = row as NSString
            var matches: [NSTextCheckingResult] = []
            var cursor = 0
            while cursor < text.length,
                  let match = timestamp.firstMatch(in: row, range: NSRange(location: cursor, length: text.length - cursor)),
                  match.range.location == cursor {
                matches.append(match)
                cursor = NSMaxRange(match.range)
            }
            guard !matches.isEmpty else { continue }
            let words = text.substring(from: cursor).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutes = Double(text.substring(with: match.range(at: 1))),
                      let seconds = Double(text.substring(with: match.range(at: 2))) else { continue }
                let time = minutes * 60 + seconds + offset
                guard time.isFinite else { continue }
                entries.append((max(0, time), words, entries.count))
            }
        }
        entries.sort { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
        let lines = entries.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
        let plain = plain?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(lines: lines, plainText: plain?.isEmpty == false ? plain : nil, instrumental: instrumental, source: source)
    }

    /// A single [00:00] tag or pasted plain text is not synchronized lyrics.
    public func hasUsableTimings(duration: TimeInterval) -> Bool {
        let words = lines.filter { !$0.text.isEmpty }
        guard duration.isFinite, duration > 0, words.count >= 2,
              Set(words.map(\.time)).count >= 2,
              let last = lines.last, last.time > 0, last.time <= duration + 2 else { return false }
        return true
    }

    public func activeLine(at position: TimeInterval) -> Int? {
        lines.last(where: { $0.time <= position })?.id
    }
}

public struct LyricsQuery: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let duration: TimeInterval
    public let album: String
    public let trackID: String?

    public init(title: String, artist: String, duration: TimeInterval, album: String = "", trackID: String? = nil) {
        self.title = title; self.artist = artist; self.duration = duration; self.album = album
        self.trackID = trackID
    }

    public var url: URL? { makeURL(search: false) }
    var searchURL: URL? { makeURL(search: true) }

    /// Discovery only: search snippets have no recording-specific timing data.
    public var webSearchURL: URL? {
        guard url != nil else { return nil }
        var parts = URLComponents(string: "https://www.google.com/search")!
        parts.queryItems = [.init(name: "q", value: "\(title) \(artist) lyrics")]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }

    private func makeURL(search: Bool) -> URL? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              duration.isFinite, (1...3600).contains(duration) else { return nil }
        var parts = URLComponents(string: "https://lrclib.net/api/" + (search ? "search" : "get"))!
        parts.queryItems = [URLQueryItem(name: "track_name", value: title),
                            URLQueryItem(name: "artist_name", value: artist)]
        if !search {
            parts.queryItems?.append(URLQueryItem(name: "duration", value: String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), duration)))
            if !album.isEmpty { parts.queryItems?.append(URLQueryItem(name: "album_name", value: album)) }
        }
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }
}

public enum LyricsLookupError: Error { case notFound, timingUnavailable, invalidResponse }

public struct LyricsClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    private struct Record: Decodable {
        let trackName: String
        let artistName: String
        let albumName: String
        let duration: Double
        let syncedLyrics: String?
        let plainLyrics: String?
        let instrumental: Bool

        func matches(_ query: LyricsQuery) -> Bool {
            Self.normalized(trackName) == Self.normalized(query.title)
                && Self.normalized(artistName) == Self.normalized(query.artist)
                && duration.isFinite && abs(duration - query.duration) <= 2
                && (query.album.isEmpty || Self.normalized(albumName) == Self.normalized(query.album))
        }

        private static func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }

        var document: LyricsDocument {
            .parse(synced: syncedLyrics, plain: plainLyrics, instrumental: instrumental)
        }
    }

    public func fetch(_ query: LyricsQuery) async throws -> LyricsDocument {
        do {
            return try await fetchLRCLIB(query)
        } catch {
            try Task.checkCancellation()
            let primaryError = error
            guard CommunityLyricsClient.url(for: query) != nil else { throw primaryError }
            do {
                return try await CommunityLyricsClient(session: session).fetch(query)
            } catch LyricsLookupError.notFound {
                throw primaryError
            } catch {
                try Task.checkCancellation()
                // Preserve a known untimed recording over a secondary outage.
                if case LyricsLookupError.timingUnavailable = primaryError { throw primaryError }
                throw error
            }
        }
    }

    private func fetchLRCLIB(_ query: LyricsQuery) async throws -> LyricsDocument {
        guard let url = query.url, let searchURL = query.searchURL else { throw LyricsLookupError.notFound }
        var matchedRecording = false
        if let data = try await get(url) {
            let record = try JSONDecoder().decode(Record.self, from: data)
            if record.matches(query) {
                matchedRecording = true
                let document = record.document
                if record.instrumental || document.hasUsableTimings(duration: query.duration) { return document }
            }
        }
        // Search is only a candidate source. Never accept a fuzzy title, different
        // artist/album, live/remix version or duration simply because it ranks first.
        try Task.checkCancellation()
        if let data = try await get(searchURL) {
            let records = try JSONDecoder().decode([Record].self, from: data)
            let matching = records.filter { $0.matches(query) }.sorted { abs($0.duration - query.duration) < abs($1.duration - query.duration) }
            for record in matching {
                matchedRecording = true
                let document = record.document
                if record.instrumental || document.hasUsableTimings(duration: query.duration) { return document }
            }
        }
        throw matchedRecording ? LyricsLookupError.timingUnavailable : LyricsLookupError.notFound
    }

    private func get(_ url: URL) async throws -> Data? {
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Futnyl/1.0 (https://github.com/adet0m1wa/futnyl)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw LyricsLookupError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw LyricsLookupError.invalidResponse }
        return data
    }
}
