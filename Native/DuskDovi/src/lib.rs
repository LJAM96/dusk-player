//! Dusk's C ABI over quietvoid's `dolby_vision` crate (libdovi, MIT): rewrites
//! Dolby Vision profile 7 HEVC samples as profile 8.1. The contract lives in
//! `include/DuskDovi/dusk_dovi.h`; keep both in sync and bump
//! `DUSK_DOVI_ABI_VERSION` on any change.
//!
//! Every exported function catches panics, so nothing unwinds into Swift.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;

use dolby_vision::rpu::ConversionMode;
use dolby_vision::rpu::dovi_rpu::DoviRpu;
use dolby_vision::rpu::rpu_data_nlq::DoviELType;

pub const DUSK_DOVI_ABI_VERSION: u32 = 1;

pub const DUSK_DOVI_OK: i32 = 0;
pub const DUSK_DOVI_ERR_INVALID_ARGUMENT: i32 = -1;
pub const DUSK_DOVI_ERR_OUTPUT_TOO_SMALL: i32 = -2;
pub const DUSK_DOVI_ERR_MALFORMED_SAMPLE: i32 = -3;
pub const DUSK_DOVI_ERR_RPU_PARSE: i32 = -4;
pub const DUSK_DOVI_ERR_RPU_CONVERT: i32 = -5;
pub const DUSK_DOVI_ERR_RPU_WRITE: i32 = -6;
pub const DUSK_DOVI_ERR_PANIC: i32 = -7;

pub const DUSK_DOVI_EL_NONE: u8 = 0;
pub const DUSK_DOVI_EL_MEL: u8 = 1;
pub const DUSK_DOVI_EL_FEL: u8 = 2;

/// Mirrors `DuskDoviSampleStats` in `dusk_dovi.h`.
#[repr(C)]
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct DuskDoviSampleStats {
    pub nal_count: u32,
    pub rpu_count: u32,
    pub el_nal_count: u32,
    pub source_profile: u8,
    pub source_el_type: u8,
    pub reserved: [u8; 2],
}

const NAL_UNSPEC62: u8 = 62;
const NAL_UNSPEC63: u8 = 63;

fn nal_type(header_byte: u8) -> u8 {
    (header_byte >> 1) & 0x3F
}

fn el_type_code(el_type: Option<&DoviELType>) -> u8 {
    match el_type {
        None => DUSK_DOVI_EL_NONE,
        Some(DoviELType::MEL) => DUSK_DOVI_EL_MEL,
        Some(DoviELType::FEL) => DUSK_DOVI_EL_FEL,
    }
}

struct ConvertedRpu {
    nal: Vec<u8>,
    source_profile: u8,
    source_el_type: u8,
}

/// dovi_tool mode 2: FEL mapping curves are reset to identity, since the
/// enhancement layer they were predicted against is dropped.
fn convert_rpu_nal(nal: &[u8]) -> Result<ConvertedRpu, i32> {
    if nal.len() < 2 || nal_type(nal[0]) != NAL_UNSPEC62 {
        return Err(DUSK_DOVI_ERR_RPU_PARSE);
    }
    let mut rpu = DoviRpu::parse_unspec62_nalu(nal).map_err(|_| DUSK_DOVI_ERR_RPU_PARSE)?;
    let source_profile = rpu.dovi_profile;
    let source_el_type = el_type_code(rpu.el_type.as_ref());
    rpu.convert_with_mode(ConversionMode::To81)
        .map_err(|_| DUSK_DOVI_ERR_RPU_CONVERT)?;
    let nal = rpu
        .write_hevc_unspec62_nalu()
        .map_err(|_| DUSK_DOVI_ERR_RPU_WRITE)?;
    Ok(ConvertedRpu {
        nal,
        source_profile,
        source_el_type,
    })
}

fn rewrite_sample(
    sample: &[u8],
    nal_length_size: usize,
    stats: &mut DuskDoviSampleStats,
) -> Result<Vec<u8>, i32> {
    // An RPU-free sample keeps its size; converted RPUs are usually smaller.
    let mut output = Vec::with_capacity(sample.len() + 64);
    let mut position = 0;
    while position < sample.len() {
        let length_end = position + nal_length_size;
        if length_end > sample.len() {
            return Err(DUSK_DOVI_ERR_MALFORMED_SAMPLE);
        }
        let nal_length = sample[position..length_end]
            .iter()
            .fold(0usize, |length, byte| (length << 8) | usize::from(*byte));
        let nal_end = length_end
            .checked_add(nal_length)
            .ok_or(DUSK_DOVI_ERR_MALFORMED_SAMPLE)?;
        if nal_length < 2 || nal_end > sample.len() {
            return Err(DUSK_DOVI_ERR_MALFORMED_SAMPLE);
        }
        let nal = &sample[length_end..nal_end];
        stats.nal_count += 1;
        match nal_type(nal[0]) {
            NAL_UNSPEC63 => stats.el_nal_count += 1,
            NAL_UNSPEC62 => {
                let converted = convert_rpu_nal(nal)?;
                stats.rpu_count += 1;
                stats.source_profile = converted.source_profile;
                stats.source_el_type = converted.source_el_type;
                append_length(&mut output, converted.nal.len(), nal_length_size)?;
                output.extend_from_slice(&converted.nal);
            }
            _ => output.extend_from_slice(&sample[position..nal_end]),
        }
        position = nal_end;
    }
    Ok(output)
}

/// `size` is 1...4. A converted RPU too long for the sample's length field
/// cannot be written back.
fn append_length(output: &mut Vec<u8>, length: usize, size: usize) -> Result<(), i32> {
    let length = u64::try_from(length).map_err(|_| DUSK_DOVI_ERR_RPU_WRITE)?;
    if length >> (size * 8) != 0 {
        return Err(DUSK_DOVI_ERR_RPU_WRITE);
    }
    let bytes = length.to_be_bytes();
    output.extend_from_slice(&bytes[8 - size..]);
    Ok(())
}

/// Copies `bytes` into the caller's buffer, or reports the size it needs.
unsafe fn deliver(bytes: &[u8], out: *mut u8, out_capacity: usize, out_len: *mut usize) -> i32 {
    unsafe {
        *out_len = bytes.len();
        if bytes.len() > out_capacity {
            return DUSK_DOVI_ERR_OUTPUT_TOO_SMALL;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len());
    }
    DUSK_DOVI_OK
}

fn guarded(body: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(DUSK_DOVI_ERR_PANIC)
}

#[unsafe(no_mangle)]
pub extern "C" fn dusk_dovi_abi_version() -> u32 {
    DUSK_DOVI_ABI_VERSION
}

/// # Safety
/// `nal` must be readable for `nal_len` bytes, `out` writable for
/// `out_capacity` bytes; `source_profile` / `source_el_type` may be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dusk_dovi_convert_rpu_nal_to_81(
    nal: *const u8,
    nal_len: usize,
    out: *mut u8,
    out_capacity: usize,
    out_len: *mut usize,
    source_profile: *mut u8,
    source_el_type: *mut u8,
) -> i32 {
    guarded(|| {
        if nal.is_null() || out.is_null() || out_len.is_null() {
            return DUSK_DOVI_ERR_INVALID_ARGUMENT;
        }
        let input = unsafe { slice::from_raw_parts(nal, nal_len) };
        let converted = match convert_rpu_nal(input) {
            Ok(converted) => converted,
            Err(code) => return code,
        };
        unsafe {
            if !source_profile.is_null() {
                *source_profile = converted.source_profile;
            }
            if !source_el_type.is_null() {
                *source_el_type = converted.source_el_type;
            }
            deliver(&converted.nal, out, out_capacity, out_len)
        }
    })
}

/// # Safety
/// `sample` must be readable for `sample_len` bytes, `out` writable for
/// `out_capacity` bytes; `stats` may be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dusk_dovi_rewrite_sample_to_81(
    sample: *const u8,
    sample_len: usize,
    nal_length_size: u8,
    out: *mut u8,
    out_capacity: usize,
    out_len: *mut usize,
    stats: *mut DuskDoviSampleStats,
) -> i32 {
    guarded(|| {
        if sample.is_null()
            || out.is_null()
            || out_len.is_null()
            || !(1..=4).contains(&nal_length_size)
        {
            return DUSK_DOVI_ERR_INVALID_ARGUMENT;
        }
        let input = unsafe { slice::from_raw_parts(sample, sample_len) };
        let mut sample_stats = DuskDoviSampleStats::default();
        let length_size = usize::from(nal_length_size);
        let output = match rewrite_sample(input, length_size, &mut sample_stats) {
            Ok(output) => output,
            Err(code) => return code,
        };
        unsafe {
            if !stats.is_null() {
                *stats = sample_stats;
            }
            deliver(&output, out, out_capacity, out_len)
        }
    })
}
