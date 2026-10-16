// Dusk's C ABI over quietvoid's dolby_vision crate (libdovi, MIT).
// Frozen: bump DUSK_DOVI_ABI_VERSION on any change.
#ifndef DUSK_DOVI_H
#define DUSK_DOVI_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define DUSK_DOVI_ABI_VERSION 1u

#define DUSK_DOVI_OK                     0
#define DUSK_DOVI_ERR_INVALID_ARGUMENT  -1  /* null pointer, or nal_length_size not in 1...4 */
#define DUSK_DOVI_ERR_OUTPUT_TOO_SMALL  -2  /* *out_len = required size; nothing written */
#define DUSK_DOVI_ERR_MALFORMED_SAMPLE  -3  /* NAL length past the end, or NAL shorter than its 2-byte header */
#define DUSK_DOVI_ERR_RPU_PARSE         -4
#define DUSK_DOVI_ERR_RPU_CONVERT       -5
#define DUSK_DOVI_ERR_RPU_WRITE         -6
#define DUSK_DOVI_ERR_PANIC             -7  /* Rust panic caught; never unwinds into the caller */

#define DUSK_DOVI_EL_NONE 0
#define DUSK_DOVI_EL_MEL  1
#define DUSK_DOVI_EL_FEL  2

typedef struct DuskDoviSampleStats {
    uint32_t nal_count;       /* NAL units in the input sample */
    uint32_t rpu_count;       /* UNSPEC62 RPU NAL units converted */
    uint32_t el_nal_count;    /* UNSPEC63 enhancement-layer NAL units dropped */
    uint8_t  source_profile;  /* dovi_profile of the last source RPU, 0 when none */
    uint8_t  source_el_type;  /* DUSK_DOVI_EL_* of the last source RPU */
    uint8_t  reserved[2];
} DuskDoviSampleStats;

uint32_t dusk_dovi_abi_version(void);

/* One HEVC UNSPEC62 NAL unit (2-byte header 0x7C 0x01 first; no start code or
   length prefix; emulation-prevention bytes in place) -> profile 8.1 RPU NAL
   (libdovi ConversionMode::To81 = dovi_tool mode 2), header included.
   source_profile / source_el_type may be NULL. */
int32_t dusk_dovi_convert_rpu_nal_to_81(const uint8_t *nal, size_t nal_len,
                                        uint8_t *out, size_t out_capacity, size_t *out_len,
                                        uint8_t *source_profile, uint8_t *source_el_type);

/* One ISO/IEC 14496-15 HEVC sample (big-endian length-prefixed NAL units,
   nal_length_size 1...4): NAL type 63 dropped, type 62 converted to 8.1, every
   other NAL copied unchanged, same order, same length-field size.
   stats may be NULL; written on OK and on OUTPUT_TOO_SMALL. */
int32_t dusk_dovi_rewrite_sample_to_81(const uint8_t *sample, size_t sample_len,
                                       uint8_t nal_length_size,
                                       uint8_t *out, size_t out_capacity, size_t *out_len,
                                       DuskDoviSampleStats *stats);

#ifdef __cplusplus
}
#endif
#endif
