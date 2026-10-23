#!/bin/bash
# Synthetic, silent AV1 fixtures for the plex-demo Movies library.
# Existing fixtures are kept. Refresh/analyze the library after generating.
set -euo pipefail
sample_root="${1:-/Volumes/Bulk/Media/Demo/Movies}"
sdr_dir="${sample_root}/AV1 SDR Test (2026)"
mp4_dir="${sample_root}/AV1 MP4 Test (2026)"
hdr_dir="${sample_root}/AV1 HDR10 Test (2026)"
mkdir -p "${sdr_dir}" "${mp4_dir}" "${hdr_dir}"
sdr="${sdr_dir}/AV1 SDR Test (2026).mkv"
mp4="${mp4_dir}/AV1 MP4 Test (2026).mp4"
hdr="${hdr_dir}/AV1 HDR10 Test (2026).mkv"

if [ ! -f "${sdr}" ]; then
    ffmpeg -hide_banner -nostdin -n \
        -f lavfi -i 'testsrc2=size=1920x1080:rate=24' \
        -f lavfi -i 'anullsrc=r=48000:cl=stereo' -t 24 \
        -map 0:v -map 1:a -map 1:a -c:v libsvtav1 -preset 12 -crf 38 \
        -svtav1-params 'lp=4:color-primaries=1:transfer-characteristics=1:matrix-coefficients=1' \
        -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
        -c:a aac -b:a 96k -metadata title='AV1 SDR Test' \
        -metadata:s:a:0 language=eng -metadata:s:a:1 language=deu "${sdr}"
fi
if [ ! -f "${mp4}" ]; then
    ffmpeg -hide_banner -nostdin -n -i "${sdr}" -map 0 -c copy \
        -movflags +faststart -metadata title='AV1 MP4 Test' "${mp4}"
fi
if [ ! -f "${hdr}" ]; then
    # SVT uses physical chromaticities/luminance, not x265's integer units.
    ffmpeg -hide_banner -nostdin -n \
        -f lavfi -i 'testsrc2=size=3840x2160:rate=24' \
        -f lavfi -i 'anullsrc=r=48000:cl=stereo' -t 12 \
        -map 0:v -map 1:a -c:v libsvtav1 -preset 12 -crf 38 \
        -svtav1-params 'lp=4:color-primaries=9:transfer-characteristics=16:matrix-coefficients=9:mastering-display=G(0.170,0.797)B(0.131,0.046)R(0.708,0.292)WP(0.3127,0.3290)L(1000,0.005):content-light=1000,400' \
        -pix_fmt yuv420p10le -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
        -c:a eac3 -b:a 192k -metadata title='AV1 HDR10 Test' -metadata:s:a:0 language=eng "${hdr}"
fi
subtitle="${sdr_dir}/AV1 SDR Test (2026).en.srt"
if [ ! -f "${subtitle}" ]; then
    printf '1\n00:00:01,000 --> 00:00:20,000\nSilent AV1 routing sample\n' > "${subtitle}"
fi
