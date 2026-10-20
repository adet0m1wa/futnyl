import AppKit

/// Coordinates shared by the Rive body and native inline lyrics, in a 270-point scene.
enum WidgetLayout {
    static let sceneWidth: CGFloat = 270
    static let lyricsHeight: CGFloat = 270

    static func windowSize(width: CGFloat, lyrics: Bool) -> NSSize {
        NSSize(width: width, height: width)
    }

    static func titleLabel(for title: String) -> String {
        let title = title.isEmpty ? "Nothing playing" : title
        return title.count > 19 ? String(title.prefix(18)) + "…" : title
    }

    static func lyricsFrame(width: CGFloat) -> NSRect {
        let scale = width / sceneWidth
        return NSRect(x: 26 * scale, y: (sceneWidth - 204) * scale,
                      width: 218 * scale, height: 174 * scale)
    }

    static func toggleFrame(width: CGFloat, lyrics: Bool) -> NSRect {
        let scale = width / sceneWidth
        let centre = lyrics ? NSPoint(x: 238, y: 25) : NSPoint(x: 136, y: 29)
        let diameter: CGFloat = lyrics ? 40 : 32
        return NSRect(x: (centre.x - diameter / 2) * scale, y: (sceneWidth - centre.y - diameter / 2) * scale,
                      width: diameter * scale, height: diameter * scale)
    }

    static func sceneValues(lyrics: Bool) -> [(String, Float)] {
        [
            ("controlsY", 237),
            ("bodyHeight", 58),
            ("bodyY", 0),
            ("speakerY", 18),
            ("speakerWellY", 21.93),
            ("turntableDetailsOpacity", lyrics ? 0 : 1),
            ("recordScale", lyrics ? 0.42 : 0.95),
            ("recordX", lyrics ? -16.217391 : 0),
            ("recordY", lyrics ? -15.065217 : -1),
        ]
    }
}
