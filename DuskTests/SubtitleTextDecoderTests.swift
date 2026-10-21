import CoreFoundation
import Foundation
import Testing
@testable import Dusk

@Suite("Subtitle text encoding")
struct SubtitleTextDecoderTests {
    struct LegacySample: Sendable {
        let encoding: CFStringEncodings
        let text: String
    }

    static let russian = "Съешь ещё этих мягких французских булок, да выпей чаю. Привет, мир! Русские субтитры должны читаться правильно."
    static let samples: [LegacySample] = [
        .init(encoding: .windowsCyrillic, text: russian),
        .init(encoding: .KOI8_R, text: russian),
        .init(encoding: .isoLatinCyrillic, text: russian),
        .init(encoding: .GB_18030_2000, text: "你好，世界！中文字幕应该正确显示。欢迎观看这部电影，这是简体中文字符测试。"),
        .init(encoding: .big5, text: "你好，世界！中文字幕應該正確顯示。歡迎觀看這部電影，這是繁體中文字符測試。"),
        .init(encoding: .shiftJIS, text: "こんにちは、世界！日本語の字幕が正しく表示されます。映画を楽しんでください。"),
        .init(encoding: .windowsArabic, text: "مرحباً بالعالم! يجب عرض الترجمة العربية بشكل صحيح من اليمين إلى اليسار. أهلاً وسهلاً بكم."),
        .init(encoding: .windowsHebrew, text: "שלום עולם! כתוביות בעברית צריכות להופיע בצורה נכונה מימין לשמאל. ברוכים הבאים לסרט."),
        .init(encoding: .isoLatinGreek, text: "Γειά σου κόσμε! Οι ελληνικοί υπότιτλοι πρέπει να εμφανίζονται σωστά. Καλή διασκέδαση."),
        .init(encoding: .dosThai, text: "สวัสดีชาวโลก คำบรรยายภาษาไทยควรแสดงอย่างถูกต้อง ยินดีต้อนรับและขอให้สนุกกับภาพยนตร์"),
        .init(encoding: .isoLatin2, text: "Zażółć gęślą jaźń. Polskie napisy powinny być wyświetlane poprawnie."),
    ]

    @Test(arguments: samples)
    func legacySidecarIsDecodedWithoutChangingCharacters(_ sample: LegacySample) throws {
        let expected = srt(sample.text)
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(sample.encoding.rawValue)
        ))
        let data = try #require(expected.data(using: encoding, allowLossyConversion: false))
        #expect(SubtitleTextDecoder.decode(data) == expected)
    }

    @Test func utf8PreservesLatinMixedScriptsAndLogicalRTLOrder() {
        let expected = srt("Latin: Hello, world! Café — Привет, мир! Ελληνικά 中文 日本語 한국어 ไทย\nالعربية: مرحباً بالعالم! 123 (ABC)\nעברית: שלום עולם! 123 (ABC)")
        #expect(SubtitleTextDecoder.decode(Data(expected.utf8)) == expected)
        #expect(SubtitleTextDecoder.decode(Data(("\u{FEFF}" + expected).utf8)) == expected)
    }

    @Test func unicodeBOMsAreHandledBeforeLegacyDetection() throws {
        let expected = srt(Self.russian + " 中文 مرحباً שלום")
        let encodings: [([UInt8], String.Encoding)] = [
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xFF, 0xFE, 0, 0], .utf32LittleEndian),
            ([0, 0, 0xFE, 0xFF], .utf32BigEndian),
        ]
        for (bom, encoding) in encodings {
            let body = try #require(expected.data(using: encoding))
            #expect(SubtitleTextDecoder.decode(Data(bom) + body) == expected)
        }
        #expect(SubtitleTextDecoder.decode(Data([0, 1, 2, 3])) == nil)
    }

    @Test(arguments: ["pgs", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "vobsub", "sub", "unknown"])
    func bitmapAndUnknownCodecsKeepOriginalDelivery(_ codec: String) async throws {
        let url = try #require(URL(string: "https://example.invalid/library/streams/1.sub"))
        let store = SubtitleFileStore()
        // Must return without attempting to download even an ASCII VobSub index
        // or a .sub URL, whose extension cannot distinguish images from text.
        #expect(try await store.prepare(url, codec: codec) == url)
        #expect(SubtitleTextDecoder.fileExtension(for: codec) == nil)
    }

    @Test func assMarkupAndFontsSurvivePreparation() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        let ass = """
        [Script Info]
        ScriptType: v4.00+
        [V4+ Styles]
        Format: Name, Fontname, Fontsize
        Style: Default,Helvetica Neue,24
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,{\\an8}Привет! 中文 مرحباً שלום
        """
        try Data(ass.utf8).write(to: source)
        let store = SubtitleFileStore()
        let prepared = try await store.prepare(source, codec: "ass")
        #expect(prepared.pathExtension == "ass")
        #expect(try Data(contentsOf: prepared) == Data(("\u{FEFF}" + ass).utf8))
    }

    @Test func savedSidecarsAreUTF8WithABOMAndOversizedOnesAreRejected() throws {
        let expected = srt(Self.russian)
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)
        ))
        let legacy = try #require(expected.data(using: encoding))
        let normalized = try #require(SubtitleTextDecoder.normalizedFileData(legacy))
        #expect(normalized.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(SubtitleTextDecoder.decode(normalized) == expected)
        // Already normalized input stays the same (no second BOM).
        #expect(SubtitleTextDecoder.normalizedFileData(normalized) == normalized)
        #expect(SubtitleTextDecoder.normalizedFileData(Data(count: SubtitleTextDecoder.maximumFileSize + 1)) == nil)
        #expect(SubtitleTextDecoder.normalizedFileData(Data([0, 1, 2, 3])) == nil)
    }

    private func srt(_ text: String) -> String {
        "1\n00:00:00,000 --> 00:00:05,000\n\(text)\n"
    }
}
