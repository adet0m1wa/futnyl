import AppKit
@preconcurrency import RiveRuntime

/// The song the vinyl showed last, kept between launches.
struct LastPlayed: Codable {
    var trackID: String
    var position: TimeInterval
    var duration: TimeInterval
}

/// Album art for the records: fetched from Spotify, squared to the label size
/// (the label's circle crops it), with the colour the music notes take.
/// Covers are kept in memory by track, and the last song's on disk so the
/// vinyl can show it before Spotify is even open.
@MainActor
final class ArtStore {
    struct Cover { let image: RiveRuntime.Image; let accent: RiveRuntime.Color }

    /// The label is drawn for 512 px art.
    private static let size = 512
    private var cache: [String: (png: Data, accent: RiveRuntime.Color)] = [:]

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Vinyl", isDirectory: true)
    }()
    private var lastURL: URL { folder.appendingPathComponent("last.json") }
    private var lastCoverURL: URL { folder.appendingPathComponent("last-cover.png") }
    private var lastAccentURL: URL { folder.appendingPathComponent("last-accent.txt") }

    /// The cover of `trackID`, which must be what Spotify is playing now
    /// (Spotify only gives the art of the current song). Nil if it moved on
    /// or there is no art.
    func cover(for trackID: String, spotify: SpotifyBridge, worker: Worker?) async -> Cover? {
        if cache[trackID] == nil {
            for attempt in 1...3 {
                if let (png, accent) = await fetch(trackID, spotify: spotify) {
                    if cache.count > 40 { cache.removeAll() }
                    cache[trackID] = (png, accent)
                    break
                }
                guard spotify.snapshot.trackID == trackID, attempt < 3 else { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let entry = cache[trackID], let worker,
              let image = try? await worker.decodeImage(from: entry.png) else { return nil }
        return Cover(image: image, accent: entry.accent)
    }

    private func fetch(_ trackID: String, spotify: SpotifyBridge) async -> (Data, RiveRuntime.Color)? {
        // Right after a change Spotify can still report the old song.
        guard let (current, url) = await spotify.currentArtworkURL(), current == trackID else {
            debugLog("artwork url not ready for \(trackID)")
            return nil
        }
        let started = Date()
        defer { debugLog("artwork download \(String(format: "%.2f", Date().timeIntervalSince(started)))s") }
        do {
            let (body, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let source = NSImage(data: body)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let png = Self.square(source) else {
                debugLog("artwork for \(trackID): unusable response")
                return nil
            }
            return (png, Self.accent(of: source))
        } catch {
            debugLog("artwork download: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Last played

    func saveLast(_ last: LastPlayed) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(last) else { return }
        try? data.write(to: lastURL)
        if let entry = cache[last.trackID] {
            try? entry.png.write(to: lastCoverURL)
            try? String(entry.accent.argbValue, radix: 16).write(to: lastAccentURL, atomically: true, encoding: .utf8)
        }
    }

    func loadLast() -> LastPlayed? {
        guard let data = try? Data(contentsOf: lastURL) else { return nil }
        return try? JSONDecoder().decode(LastPlayed.self, from: data)
    }

    func lastCover(worker: Worker?) async -> Cover? {
        guard let worker, let png = try? Data(contentsOf: lastCoverURL),
              let image = try? await worker.decodeImage(from: png) else { return nil }
        let hex = (try? String(contentsOf: lastAccentURL, encoding: .utf8)) ?? ""
        let accent = UInt32(hex.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16).map(RiveRuntime.Color.init)
        if let last = loadLast() { cache[last.trackID] = (png, accent ?? Self.defaultAccent) }
        return Cover(image: image, accent: accent ?? Self.defaultAccent)
    }

    // MARK: Image work

    /// The green the notes have without a cover.
    static let defaultAccent = RiveRuntime.Color(red: 63, green: 175, blue: 124)

    /// The cover filling a 512 px square (non-square art is centre-cropped).
    static func square(_ source: CGImage) -> Data? {
        let n = size
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let scale = CGFloat(n) / CGFloat(min(source.width, source.height))
        let w = CGFloat(source.width) * scale, h = CGFloat(source.height) * scale
        ctx.draw(source, in: CGRect(x: (CGFloat(n) - w) / 2, y: (CGFloat(n) - h) / 2, width: w, height: h))
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// The cover's most common vivid hue, kept dark enough to read on the
    /// light body. A cover without colour gives a grey of its own shade.
    static func accent(of image: CGImage) -> RiveRuntime.Color {
        let n = 32
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return defaultAccent }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        var weight = [Double](repeating: 0, count: 24)
        var brightness = 0.0
        var sum = [(Double, Double, Double)](repeating: (0, 0, 0), count: 24)
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            let c = NSColor(red: r, green: g, blue: b, alpha: 1)
            let s = Double(c.saturationComponent), v = Double(c.brightnessComponent)
            brightness += v / Double(n * n)
            guard s > 0.25, v > 0.2 else { continue }
            let w = s * s * v
            let bucket = min(23, Int(Double(c.hueComponent) * 24))
            weight[bucket] += w
            sum[bucket].0 += r * w; sum[bucket].1 += g * w; sum[bucket].2 += b * w
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0.5 else {
            // Black-and-white art: a grey, dark enough to read on the body.
            let grey = UInt8(min(max(brightness, 0.22), 0.5) * 255)
            return RiveRuntime.Color(red: grey, green: grey, blue: grey)
        }
        let w = weight[best]
        let c = NSColor(red: sum[best].0 / w, green: sum[best].1 / w, blue: sum[best].2 / w, alpha: 1)
        let o = NSColor(hue: c.hueComponent, saturation: max(c.saturationComponent, 0.5),
                        brightness: min(max(c.brightnessComponent, 0.45), 0.78), alpha: 1)
        return RiveRuntime.Color(red: UInt8(o.redComponent * 255), green: UInt8(o.greenComponent * 255),
                                 blue: UInt8(o.blueComponent * 255))
    }
}
