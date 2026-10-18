# DuskDovi test vectors

`fel_orig.bin`, `fel_to_81.bin`, `mel_orig.bin` and `mel_to_81.bin` are copied
unchanged from [quietvoid/dovi_tool](https://github.com/quietvoid/dovi_tool)
`assets/tests/` (MIT License, Copyright (c) 2026 quietvoid; full text in
`Dusk/Resources/ThirdPartyNotices.txt`). Each is one Annex-B RPU: start code
`00 00 00 01`, then the UNSPEC62 payload from `0x19`, emulation-prevention bytes
in place.

- `mel_to_81.bin` is the dovi_tool mode 2 (`ConversionMode::To81`) output of
  `mel_orig.bin`.
- `fel_to_81.bin` keeps the FEL mapping curves (upstream produces it via
  FEL → MEL → 8.1, which equals mode 4, `To81MappingPreserved`). Mode 2 on a FEL
  RPU resets the mapping to identity instead.
- `fel_to_81_mode2.bin` is Dusk's own vector: the `dolby_vision` 3.4.0 mode 2
  output of `fel_orig.bin`, written in the same Annex-B form. `tests/convert.rs`
  checks that it equals `fel_to_81.bin` with `remove_mapping()` applied.

The Swift tests carry the same bytes as base64 (`DuskTests/DolbyVision7Fixtures.swift`).
