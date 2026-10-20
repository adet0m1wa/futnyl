import AppKit
@preconcurrency import RiveRuntime

enum WidgetAppearance: String, CaseIterable {
    case system, light, dark

    var title: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension VinylController {
    // Palette names are bound to the matching original colours in scene.rml.
    static let themeColors: [(String, UInt32, UInt32)] = [
        ("themeFFF6F5F2", 0xFFF6F5F2, 0xFF3B3D40),
        ("themeFFECEAE6", 0xFFECEAE6, 0xFF303235),
        ("themeFFE3E0DB", 0xFFE3E0DB, 0xFF25272A),
        ("themeFFE6E3DE", 0xFFE6E3DE, 0xFF3B3D40),
        ("themeFFF1EFEC", 0xFFF1EFEC, 0xFF4A4C50),
        ("themeFF8A8A8A", 0xFF8A8A8A, 0xFFD7D9DB),
        ("themeFFE4E1DC", 0xFFE4E1DC, 0xFF202225),
        ("themeFFF4F4F4", 0xFFF4F4F4, 0xFF44464A),
        ("theme00F4F4F4", 0x00F4F4F4, 0x0044464A),
        ("themeFFF6F4F0", 0xFFF6F4F0, 0xFF45474B),
        ("themeFFD8D4CE", 0xFFD8D4CE, 0xFF26282B),
        ("themeFFE6E2DC", 0xFFE6E2DC, 0xFF36383C),
        ("themeE6FFFFFF", 0xE6FFFFFF, 0xFF55585D),
        ("theme99FFFFFF", 0x99FFFFFF, 0x405D6065),
        ("themeB3FFFFFF", 0xB3FFFFFF, 0xFF55585D),
        ("themeFFDFDFDF", 0xFFDFDFDF, 0xFF4B4D51),
        ("themeFFF3F3F3", 0xFFF3F3F3, 0xFF85888D),
        ("themeFFB7B7B7", 0xFF666866, 0xFFE1E3E5),
        ("themeFFFAF9F7", 0xFFFAF9F7, 0xFF505358),
        ("themeFFE2DFDA", 0xFFE2DFDA, 0xFF303237),
        ("themeFFE5E2DD", 0xFFE5E2DD, 0xFF3A3C40),
    ]
}
