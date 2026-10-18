# DuskDovi third-party licenses

`DuskDovi.xcframework` statically links the crates in `Cargo.lock` plus the Rust
standard library. All of them can be used under MIT, which is the license Dusk
elects. The shipped notice is `Dusk/Resources/ThirdPartyNotices.txt` (bundled in
both apps); update it whenever `Cargo.lock` or the toolchain changes.

| Crate | Version | License (SPDX, as published) | Copyright |
|---|---|---|---|
| dolby_vision | 3.4.0 | MIT | 2026 quietvoid |
| bitvec_helpers | 4.0.2 | MIT | 2026 quietvoid |
| bitvec | 1.1.1 | MIT | 2018 myrrlyn (Alexander Payne) |
| funty | 2.0.0 | MIT | 2020 myrrlyn (Alexander Payne) |
| wyz | 0.5.1 | MIT | 2018 myrrlyn (Alexander Payne) |
| radium | 0.7.0 | MIT | 2019 kneecaw (Nika Layzell) |
| tap | 1.0.1 | MIT | 2017 Elliot Linder |
| bitstream-io | 4.10.0 | MIT OR Apache-2.0 | 2017 Brian Langenberger |
| no_std_io2 | 0.9.4 | Apache-2.0 OR MIT | 2020-2021 Brendan Molloy |
| memchr | 2.8.3 | Unlicense OR MIT | 2015 Andrew Gallant |
| crc | 3.4.0 | MIT OR Apache-2.0 | 2017 crc-rs Developers |
| crc-catalog | 2.5.0 | MIT OR Apache-2.0 | 2019 Akhil Velagapudi |
| anyhow | 1.0.104 | MIT OR Apache-2.0 | David Tolnay |
| tinyvec | 1.13.3 | Zlib OR Apache-2.0 OR MIT | 2019 Daniel "Lokathor" Gee |
| Rust std (1.96.0) | — | MIT OR Apache-2.0 | The Rust Project Developers |

Test vectors in `tests/fixtures/` come from dovi_tool (MIT, see its README).

App Store: the library is a static archive of ahead-of-time compiled code. It
generates no code at runtime, loads nothing dynamically, and calls only public
libSystem APIs.
