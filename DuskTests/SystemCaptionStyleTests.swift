import Testing
@testable import Dusk

@Suite("System caption style → libvlc text renderer")
@MainActor
struct SystemCaptionStyleTests {
    private func caption(
        foreground: SystemCaptionStyle.Color = .white,
        background: SystemCaptionStyle.Color = SystemCaptionStyle.Color(red: 0, green: 0, blue: 0, alpha: 0),
        edge: SystemCaptionStyle.Edge = .none,
        relativeSize: Double = 1,
        fontFamily: String? = nil
    ) -> SystemCaptionStyle {
        SystemCaptionStyle(
            foreground: foreground,
            background: background,
            edge: edge,
            relativeSize: relativeSize,
            fontFamily: fontFamily
        )
    }

    @Test func colorsAndOpacitiesMapToFreetypeIntegers() {
        let style = VLCTextRendererStyle(
            caption: caption(
                foreground: SystemCaptionStyle.Color(red: 1, green: 1, blue: 0, alpha: 0.5),
                background: SystemCaptionStyle.Color(red: 0, green: 0, blue: 1, alpha: 0.75)
            ),
            size: .medium
        )

        #expect(style.integers["freetype-color"] == 0xFFFF00)
        #expect(style.integers["freetype-opacity"] == 128)
        #expect(style.integers["freetype-background-color"] == 0x0000FF)
        #expect(style.integers["freetype-background-opacity"] == 191)
    }

    @Test func noEdgeTurnsOutlineAndShadowOff() {
        let style = VLCTextRendererStyle(caption: caption(edge: .none), size: .medium)

        #expect(style.integers["freetype-outline-thickness"] == 0)
        #expect(style.integers["freetype-outline-opacity"] == 0)
        #expect(style.integers["freetype-shadow-opacity"] == 0)
    }

    @Test func outlineEdgeDrawsANormalOutlineOnly() {
        let style = VLCTextRendererStyle(caption: caption(edge: .outline), size: .medium)

        #expect(style.integers["freetype-outline-thickness"] == 4)
        #expect(style.integers["freetype-outline-opacity"] == 255)
        #expect(style.integers["freetype-shadow-opacity"] == 0)
    }

    @Test func shadowEdgesPointTheShadowByStyle() {
        let drop = VLCTextRendererStyle(caption: caption(edge: .dropShadow), size: .medium)
        let depressed = VLCTextRendererStyle(caption: caption(edge: .depressed), size: .medium)

        #expect(drop.integers["freetype-shadow-opacity"] == 255)
        #expect(drop.integers["freetype-outline-thickness"] == 0)
        #expect(drop.floats["freetype-shadow-angle"] == -45)
        #expect(depressed.floats["freetype-shadow-angle"] == 135)
    }

    @Test func hiddenSystemFontFallsBackToLibVLCDefault() {
        #expect(VLCTextRendererStyle(caption: caption(fontFamily: nil), size: .medium).font == VLCTextRendererStyle.defaultFont)
        #expect(VLCTextRendererStyle(caption: caption(fontFamily: "Menlo"), size: .medium).font == "Menlo")
    }

    @Test func hiddenSystemFamiliesMapToVisibleOnes() {
        #expect(SystemCaptionStyle.visibleFontFamily(".AppleSystemUIFontMonospaced") == "Menlo")
        #expect(SystemCaptionStyle.visibleFontFamily(".AppleSystemUIFontSerif") == "Georgia")
        #expect(SystemCaptionStyle.visibleFontFamily(".AppleSystemUIFont") == nil)
        #expect(SystemCaptionStyle.visibleFontFamily("Avenir Next") == "Avenir Next")
    }

    @Test func duskSizeStepScalesOnTopOfTheSystemSize() {
        let normal = PlaybackSubtitleStyle.vlcRelativeFontSize(for: .medium)
        let systemLarge = PlaybackSubtitleStyle.vlcRelativeFontSize(for: .medium, systemScale: 1.5)
        let both = PlaybackSubtitleStyle.vlcRelativeFontSize(for: .large, systemScale: 1.5)

        // A smaller libvlc divisor draws larger text.
        #expect(systemLarge < normal)
        #expect(both < systemLarge)
        #expect(
            PlaybackSubtitleStyle.avPlayerRelativeFontSize(for: .small, systemScale: 2)
                == 2 * PlaybackSubtitleStyle.avPlayerRelativeFontSize(for: .small)
        )
    }

    @Test func styleChangesAreDetectedForReload() {
        let before = VLCTextRendererStyle(caption: caption(edge: .none), size: .medium)
        #expect(before == VLCTextRendererStyle(caption: caption(edge: .none), size: .medium))
        #expect(before != VLCTextRendererStyle(caption: caption(edge: .outline), size: .medium))
        #expect(before != VLCTextRendererStyle(caption: caption(edge: .none), size: .large))
    }
}
