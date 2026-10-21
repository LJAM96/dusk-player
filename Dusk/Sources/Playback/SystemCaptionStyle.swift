import CoreGraphics
import CoreText
import Foundation
import MediaAccessibility

/// The subtitle style picked in Settings › Accessibility › Subtitles &
/// Captioning › Style, read through MediaAccessibility. Dusk always follows it
/// (there is no Dusk-only look): AVPlayer's legible renderer applies it by
/// itself as long as Dusk does not override it, and VLCKit gets it translated
/// into libvlc's freetype text renderer options (`VLCTextRendererStyle`).
/// Dusk's own Subtitle Size step scales on top of the system size.
struct SystemCaptionStyle: Equatable, Sendable {
    struct Color: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        static let white = Color(red: 1, green: 1, blue: 1, alpha: 1)
        static let black = Color(red: 0, green: 0, blue: 0, alpha: 1)
    }

    enum Edge: Equatable, Sendable {
        case none
        case outline
        case dropShadow
        case raised
        case depressed
    }

    var foreground: Color
    /// Character background, or the window colour when the style only has a
    /// window: libvlc draws one box behind the text either way.
    var background: Color
    var edge: Edge
    /// The system text size; 1 is the style's normal size.
    var relativeSize: Double
    /// Family of the style's font, nil for the system's own face. The
    /// system faces are hidden families (`.AppleSystemUIFont…`) that
    /// libvlc's CoreText lookup cannot resolve, so the monospaced and serif
    /// ones (the Classic style uses the monospaced) map to a visible family.
    var fontFamily: String?

    /// Posted (on the local center) whenever the user changes the style.
    static let didChangeNotification = Notification.Name(
        kMACaptionAppearanceSettingsChangedNotification as String
    )

    static func current() -> SystemCaptionStyle {
        let domain = MACaptionAppearanceDomain.user
        let foreground = Color(
            MACaptionAppearanceCopyForegroundColor(domain, nil).takeRetainedValue(),
            opacity: MACaptionAppearanceGetForegroundOpacity(domain, nil)
        )
        let characterBackground = Color(
            MACaptionAppearanceCopyBackgroundColor(domain, nil).takeRetainedValue(),
            opacity: MACaptionAppearanceGetBackgroundOpacity(domain, nil)
        )
        let window = Color(
            MACaptionAppearanceCopyWindowColor(domain, nil).takeRetainedValue(),
            opacity: MACaptionAppearanceGetWindowOpacity(domain, nil)
        )
        let font = MACaptionAppearanceCopyFontDescriptorForStyle(domain, nil, .default).takeRetainedValue()
        let family = CTFontDescriptorCopyAttribute(font, kCTFontFamilyNameAttribute) as? String

        return SystemCaptionStyle(
            foreground: foreground,
            background: characterBackground.alpha > 0 ? characterBackground : window,
            edge: Edge(MACaptionAppearanceGetTextEdgeStyle(domain, nil)),
            relativeSize: Double(MACaptionAppearanceGetRelativeCharacterSize(domain, nil)),
            fontFamily: family.flatMap(visibleFontFamily)
        )
    }

    static func visibleFontFamily(_ family: String) -> String? {
        guard family.hasPrefix(".") else { return family.isEmpty ? nil : family }
        if family.contains("Mono") { return "Menlo" }
        if family.contains("Serif") { return "Georgia" }
        return nil
    }
}

private extension SystemCaptionStyle.Color {
    init(_ color: CGColor, opacity: CGFloat) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB).flatMap {
            color.converted(to: $0, intent: .defaultIntent, options: nil)
        } ?? color
        let components = srgb.components ?? []
        let rgb: [CGFloat] = switch components.count {
        case 4...: Array(components.prefix(3))
        case 2...: Array(repeating: components[0], count: 3)
        default: [1, 1, 1]
        }
        self.init(
            red: Double(rgb[0]),
            green: Double(rgb[1]),
            blue: Double(rgb[2]),
            alpha: Double(srgb.alpha * opacity)
        )
    }
}

private extension SystemCaptionStyle.Edge {
    init(_ style: MACaptionAppearanceTextEdgeStyle) {
        switch style {
        case .none: self = .none
        case .uniform: self = .outline
        case .raised: self = .raised
        case .depressed: self = .depressed
        default: self = .dropShadow
        }
    }
}

/// libvlc 3.x `freetype-*` text renderer values for a caption style. The
/// renderer reads them when it is created, so a change needs the media
/// reopened (see `VLCKitEngine.reloadForSubtitleStylingIfNeeded`).
@MainActor
struct VLCTextRendererStyle: Equatable {
    /// libvlc's own Apple default family, used for the system face. Never
    /// empty: libvlc's live style update strdup()s the value and crashes on "".
    static let defaultFont = "Helvetica Neue"

    var font: String
    /// `freetype-rel-fontsize`: video height / this = font height.
    var relativeFontSize: Int
    var integers: [String: Int]
    var floats: [String: Float]

    init(caption: SystemCaptionStyle, size: SubtitleFontSize) {
        font = caption.fontFamily ?? Self.defaultFont
        relativeFontSize = PlaybackSubtitleStyle.vlcRelativeFontSize(for: size, systemScale: caption.relativeSize)

        let edgeOpacity = Self.opacity(caption.foreground.alpha)
        var integers = [
            "freetype-color": Self.rgb(caption.foreground),
            "freetype-opacity": Self.opacity(caption.foreground.alpha),
            "freetype-background-color": Self.rgb(caption.background),
            "freetype-background-opacity": Self.opacity(caption.background.alpha),
            "freetype-outline-color": 0,
            "freetype-outline-opacity": 0,
            "freetype-outline-thickness": 0,
            "freetype-shadow-color": 0,
            "freetype-shadow-opacity": 0,
        ]
        // libvlc's angle is counter-clockwise from the x axis: -45 casts the
        // shadow down-right (light from the top left), 135 up-left.
        var shadowAngle: Float = -45
        var shadowDistance: Float = 0.06
        switch caption.edge {
        case .none:
            break
        case .outline:
            integers["freetype-outline-opacity"] = edgeOpacity
            integers["freetype-outline-thickness"] = 4
        case .dropShadow:
            integers["freetype-shadow-opacity"] = edgeOpacity
        case .raised:
            integers["freetype-shadow-opacity"] = edgeOpacity
            shadowDistance = 0.03
        case .depressed:
            integers["freetype-shadow-opacity"] = edgeOpacity
            shadowAngle = 135
            shadowDistance = 0.03
        }
        self.integers = integers
        floats = [
            "freetype-shadow-angle": shadowAngle,
            "freetype-shadow-distance": shadowDistance,
        ]
    }

    private static func rgb(_ color: SystemCaptionStyle.Color) -> Int {
        func channel(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return channel(color.red) << 16 | channel(color.green) << 8 | channel(color.blue)
    }

    private static func opacity(_ alpha: Double) -> Int {
        Int((min(max(alpha, 0), 1) * 255).rounded())
    }
}
