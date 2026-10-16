import Foundation

/// Dolby Vision RPU test vectors, shared with `Native/DuskDovi/tests/fixtures/`.
///
/// The originals and `melConverted` come from quietvoid/dovi_tool `assets/tests/`
/// (MIT License, Copyright (c) 2026 quietvoid,
/// https://github.com/quietvoid/dovi_tool; full notice in
/// `Dusk/Resources/ThirdPartyNotices.txt`). Each blob is the file as published:
/// Annex-B start code `00 00 00 01`, then the RPU payload from `0x19`.
enum DolbyVision7Fixtures {
    /// Profile 7 FEL RPU (dovi_tool `assets/tests/fel_orig.bin`).
    static let felOriginal = annexB("""
        AAAAARkICQhAYTZQriAAIAgCAIAgCAIAf4Af/AD/wAH/+gAAAwEAAAMA0AAACAAABoAAAEAAADQAAAMCAAADAaAAABAAAA0A
        AAMAgAAAaAAABAAAAwNAAAAgAAAKhtnmey+GPvwYnmAp6YwGuMVmp81fjf/LbYw544qZgbhspnkPQF9DTLfYDp4Ew0n9O7d+
        ws1d46FH1EwKLoBiFkoCm11ZUA7Tj1jEbE7BOhRYLP8wI1NtV7u25BFIO5KWZBNpj85rwxvWIPrdQFu+9GQxYLHwG/Lu+/Kl
        4vPMtKvzzDmDd551aDEbAEgAAEAEAEAAAEASAAAQAQAQAAAQBIAABABABAAAByVmAAA16iVm+fzrHCVmRMoAAAMBAAADAAgA
        AAMACAAAAwAcNiJDAYYKXjCOBRQAAAMBpj5a//8AAAMAAAMAAAMAAGAgD4DhUYAwCABZyhIAwCghjfglgAgAYUAAAgIqUSCI
        BQAAAwACKBFQEgwH0AACDWABXrjynYKA
        """)

    /// `felOriginal` after dolby_vision 3.4.0 mode 2: profile 8.1, FEL mapping reset
    /// (Dusk's vector, `Native/DuskDovi/tests/fixtures/fel_to_81_mode2.bin`).
    static let felConverted = annexB("""
        AAAAARkICQhAYTZQbwA/+AH/wA//0AAACAAABoAAAEAAADQAAAMCAAADAclZgAANeolZvn86xwlZkTKAAABAAAADAgAAAwAC
        AAADAAcNiJDAYYKXjCOBRQAAAwBpj5a//8AAAAMAAAMAAAMAGAgD4DhUYDAIAFnKEgDAKCGN+CWACABhQAACAipRIIgFAAAD
        AAIoEVASDAfQAAINYAFeaGDlUoA=
        """)

    /// Profile 7 MEL RPU (dovi_tool `assets/tests/mel_orig.bin`).
    static let melOriginal = annexB("""
        AAAAARkICQhAYTZQrwA/+AH/wA/8AB//oAAAEAAADQAAAwCAAABoAAAEAAADAABAAAAgAAAgAAADAAQAAAMCAAADAgAAAwAA
        QAAAIAAAIAAANErMAABr1ErN8/nWOErMiZQAAAMCAAADABAAAAMAEAAAAwA4bESGAwwUvGEcCigAAAMDTHy1//4AAAMAAAMA
        AAMAAMBAHwHCogAwCABPkw8BARXwrkSDAfQAAIAAAAMAAPkfd+6A
        """)

    /// `melOriginal` after mode 2 (dovi_tool `assets/tests/mel_to_81.bin`).
    static let melConverted = annexB("""
        AAAAARkICQhAYTZQbwA/+AH/wA//0AAACAAABoAAAEAAADQAAAMCAAADAaJWYAADXqJWb5/OscJWZEygAAAQAAADAIAAAAMA
        gAAAAwHDYiQwGGCl4wjgUUAAABpj5a//8AAAAwAAAwAAAwAGAgD4DhUQMAgAT5MPAQEV8K5EgwH0AACAAAADAACM9CDVgA==
        """)

    /// The RPU as an HEVC UNSPEC62 NAL unit: header `7C 01` replaces the start code.
    static func rpuNAL(_ annexB: Data) -> Data {
        Data([0x7C, 0x01]) + annexB.dropFirst(4)
    }

    private static func annexB(_ base64: String) -> Data {
        Data(base64Encoded: base64.filter { !$0.isWhitespace })!
    }
}
