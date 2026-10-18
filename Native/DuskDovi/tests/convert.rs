//! Golden tests for the C ABI. Fixtures: see tests/fixtures/README.md.

use std::ptr;

use dolby_vision::rpu::dovi_rpu::DoviRpu;
use dusk_dovi::*;

const FEL_ORIG: &[u8] = include_bytes!("fixtures/fel_orig.bin");
const FEL_TO_81: &[u8] = include_bytes!("fixtures/fel_to_81.bin");
const FEL_TO_81_MODE2: &[u8] = include_bytes!("fixtures/fel_to_81_mode2.bin");
const MEL_ORIG: &[u8] = include_bytes!("fixtures/mel_orig.bin");
const MEL_TO_81: &[u8] = include_bytes!("fixtures/mel_to_81.bin");

/// Fixture files are Annex-B (`00 00 00 01` + RPU payload); the ABI takes
/// the NAL unit itself, header `7C 01` first.
fn rpu_nal(annex_b: &[u8]) -> Vec<u8> {
    assert_eq!(&annex_b[..4], &[0, 0, 0, 1]);
    let mut nal = vec![0x7C, 0x01];
    nal.extend_from_slice(&annex_b[4..]);
    nal
}

fn convert_nal(nal: &[u8]) -> Result<(Vec<u8>, u8, u8), i32> {
    let mut out = vec![0u8; nal.len() + 1024];
    let mut out_len = 0usize;
    let mut profile = 0u8;
    let mut el_type = 0u8;
    let status = unsafe {
        dusk_dovi_convert_rpu_nal_to_81(
            nal.as_ptr(),
            nal.len(),
            out.as_mut_ptr(),
            out.len(),
            &mut out_len,
            &mut profile,
            &mut el_type,
        )
    };
    if status != DUSK_DOVI_OK {
        return Err(status);
    }
    out.truncate(out_len);
    Ok((out, profile, el_type))
}

fn rewrite(
    sample: &[u8],
    length_size: u8,
    capacity: usize,
) -> (i32, Vec<u8>, usize, DuskDoviSampleStats) {
    let mut out = vec![0xAAu8; capacity.max(1)];
    let mut out_len = 0usize;
    let mut stats = DuskDoviSampleStats::default();
    let status = unsafe {
        dusk_dovi_rewrite_sample_to_81(
            sample.as_ptr(),
            sample.len(),
            length_size,
            out.as_mut_ptr(),
            capacity,
            &mut out_len,
            &mut stats,
        )
    };
    (status, out, out_len, stats)
}

fn length_prefixed(nals: &[&[u8]], length_size: usize) -> Vec<u8> {
    let mut sample = Vec::new();
    for nal in nals {
        let length = (nal.len() as u64).to_be_bytes();
        sample.extend_from_slice(&length[8 - length_size..]);
        sample.extend_from_slice(nal);
    }
    sample
}

const SLICE_NAL: &[u8] = &[0x02, 0x01, 0xD0, 0x11, 0x22, 0x33, 0x44];
const EL_NAL: &[u8] = &[0x7E, 0x01, 0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF];

#[test]
fn abi_version_matches_header() {
    assert_eq!(dusk_dovi_abi_version(), 1);
}

#[test]
fn mel_rpu_converts_to_upstream_golden() {
    let (converted, profile, el_type) = convert_nal(&rpu_nal(MEL_ORIG)).unwrap();
    assert_eq!(converted, rpu_nal(MEL_TO_81));
    assert_eq!(profile, 7);
    assert_eq!(el_type, DUSK_DOVI_EL_MEL);
}

#[test]
fn fel_rpu_converts_with_mapping_reset() {
    let (converted, profile, el_type) = convert_nal(&rpu_nal(FEL_ORIG)).unwrap();
    assert_eq!(converted, rpu_nal(FEL_TO_81_MODE2));
    assert_eq!(profile, 7);
    assert_eq!(el_type, DUSK_DOVI_EL_FEL);

    // Upstream's fel_to_81.bin keeps the FEL mapping curves (dovi_tool mode 4).
    // Mode 2 is exactly that RPU with the mapping reset to identity.
    let mut upstream = DoviRpu::parse_unspec62_nalu(&rpu_nal(FEL_TO_81)).unwrap();
    upstream.remove_mapping();
    assert_eq!(converted, upstream.write_hevc_unspec62_nalu().unwrap());

    let reparsed = DoviRpu::parse_unspec62_nalu(&converted).unwrap();
    assert_eq!(reparsed.dovi_profile, 8);
    assert!(reparsed.el_type.is_none());
}

#[test]
fn sample_drops_enhancement_layer_and_converts_rpu() {
    let rpu = rpu_nal(FEL_ORIG);
    let expected_rpu = rpu_nal(FEL_TO_81_MODE2);
    for length_size in [2u8, 4] {
        let size = usize::from(length_size);
        let sample = length_prefixed(&[SLICE_NAL, EL_NAL, &rpu], size);
        let expected = length_prefixed(&[SLICE_NAL, &expected_rpu], size);

        let (status, out, out_len, stats) = rewrite(&sample, length_size, sample.len() + 1024);
        assert_eq!(status, DUSK_DOVI_OK);
        assert_eq!(&out[..out_len], &expected[..]);
        assert_eq!(stats.nal_count, 3);
        assert_eq!(stats.rpu_count, 1);
        assert_eq!(stats.el_nal_count, 1);
        assert_eq!(stats.source_profile, 7);
        assert_eq!(stats.source_el_type, DUSK_DOVI_EL_FEL);
    }
}

#[test]
fn sample_without_dolby_vision_is_copied() {
    let sample = length_prefixed(&[SLICE_NAL, SLICE_NAL], 4);
    let (status, out, out_len, stats) = rewrite(&sample, 4, sample.len());
    assert_eq!(status, DUSK_DOVI_OK);
    assert_eq!(&out[..out_len], &sample[..]);
    assert_eq!(stats.nal_count, 2);
    assert_eq!(stats.rpu_count, 0);
    assert_eq!(stats.source_profile, 0);
    assert_eq!(stats.source_el_type, DUSK_DOVI_EL_NONE);
}

#[test]
fn small_output_reports_required_size_and_writes_nothing() {
    let sample = length_prefixed(&[SLICE_NAL, &rpu_nal(MEL_ORIG)], 4);
    let expected = length_prefixed(&[SLICE_NAL, &rpu_nal(MEL_TO_81)], 4);

    let (status, out, out_len, stats) = rewrite(&sample, 4, 8);
    assert_eq!(status, DUSK_DOVI_ERR_OUTPUT_TOO_SMALL);
    assert_eq!(out_len, expected.len());
    assert!(out.iter().all(|byte| *byte == 0xAA));
    assert_eq!(stats.rpu_count, 1);
    assert_eq!(stats.source_el_type, DUSK_DOVI_EL_MEL);
}

#[test]
fn truncated_sample_is_malformed() {
    let mut sample = length_prefixed(&[SLICE_NAL], 4);
    sample.pop();
    assert_eq!(rewrite(&sample, 4, 1024).0, DUSK_DOVI_ERR_MALFORMED_SAMPLE);

    // Length field itself cut short.
    assert_eq!(
        rewrite(&[0, 0, 0], 4, 1024).0,
        DUSK_DOVI_ERR_MALFORMED_SAMPLE
    );

    // NAL shorter than its 2-byte header.
    assert_eq!(
        rewrite(&[0, 0, 0, 1, 0x02], 4, 1024).0,
        DUSK_DOVI_ERR_MALFORMED_SAMPLE
    );
}

#[test]
fn garbage_rpu_fails_to_parse() {
    let garbage = [0x7C, 0x01, 0x19, 0x08, 0x09, 0x00, 0x01, 0x02, 0x03, 0x04];
    assert_eq!(convert_nal(&garbage), Err(DUSK_DOVI_ERR_RPU_PARSE));
    assert_eq!(convert_nal(SLICE_NAL), Err(DUSK_DOVI_ERR_RPU_PARSE));

    let sample = length_prefixed(&[SLICE_NAL, &garbage], 4);
    assert_eq!(rewrite(&sample, 4, 1024).0, DUSK_DOVI_ERR_RPU_PARSE);
}

#[test]
fn one_byte_length_fields_are_kept() {
    let sample = length_prefixed(&[SLICE_NAL, &rpu_nal(MEL_ORIG)], 1);
    let expected = length_prefixed(&[SLICE_NAL, &rpu_nal(MEL_TO_81)], 1);
    let (status, out, out_len, stats) = rewrite(&sample, 1, 1024);
    assert_eq!(status, DUSK_DOVI_OK);
    assert_eq!(&out[..out_len], &expected[..]);
    assert_eq!(stats.rpu_count, 1);
}

#[test]
fn invalid_arguments_are_rejected() {
    let sample = length_prefixed(&[SLICE_NAL], 4);
    let mut out = [0u8; 64];
    let mut out_len = 0usize;
    unsafe {
        assert_eq!(
            dusk_dovi_rewrite_sample_to_81(
                ptr::null(),
                0,
                4,
                out.as_mut_ptr(),
                out.len(),
                &mut out_len,
                ptr::null_mut()
            ),
            DUSK_DOVI_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            dusk_dovi_rewrite_sample_to_81(
                sample.as_ptr(),
                sample.len(),
                4,
                ptr::null_mut(),
                64,
                &mut out_len,
                ptr::null_mut()
            ),
            DUSK_DOVI_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            dusk_dovi_rewrite_sample_to_81(
                sample.as_ptr(),
                sample.len(),
                4,
                out.as_mut_ptr(),
                out.len(),
                ptr::null_mut(),
                ptr::null_mut()
            ),
            DUSK_DOVI_ERR_INVALID_ARGUMENT
        );
        for length_size in [0u8, 5] {
            assert_eq!(
                dusk_dovi_rewrite_sample_to_81(
                    sample.as_ptr(),
                    sample.len(),
                    length_size,
                    out.as_mut_ptr(),
                    out.len(),
                    &mut out_len,
                    ptr::null_mut()
                ),
                DUSK_DOVI_ERR_INVALID_ARGUMENT
            );
        }
        assert_eq!(
            dusk_dovi_convert_rpu_nal_to_81(
                ptr::null(),
                0,
                out.as_mut_ptr(),
                out.len(),
                &mut out_len,
                ptr::null_mut(),
                ptr::null_mut()
            ),
            DUSK_DOVI_ERR_INVALID_ARGUMENT
        );
    }

    // Null stats / profile outputs are allowed.
    let nal = rpu_nal(MEL_ORIG);
    let mut big = vec![0u8; 1024];
    let status = unsafe {
        dusk_dovi_convert_rpu_nal_to_81(
            nal.as_ptr(),
            nal.len(),
            big.as_mut_ptr(),
            big.len(),
            &mut out_len,
            ptr::null_mut(),
            ptr::null_mut(),
        )
    };
    assert_eq!(status, DUSK_DOVI_OK);
    assert_eq!(&big[..out_len], &rpu_nal(MEL_TO_81)[..]);
}
