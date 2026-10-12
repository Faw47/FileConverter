#!/usr/bin/env bash
# Generates media fixtures used by output-inspecting tests.
# Output: Tests/Fixtures/Generated/ (git-ignored). Fixtures whose tool is
# missing are skipped with a notice; the matching tests skip themselves.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/Tests/Fixtures/Generated"
mkdir -p "${OUT}/same_name"

have() { command -v "$1" >/dev/null 2>&1; }
skip() { echo "skip: $1 ($2 not installed)"; }

FF=(ffmpeg -y -hide_banner -loglevel error)

if have ffmpeg; then
  "${FF[@]}" -f lavfi -i testsrc2=size=1920x1080:rate=30:duration=2 \
    -f lavfi -i sine=frequency=440:duration=2 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 128k -shortest \
    "${OUT}/landscape_1920x1080_h264.mp4"

  # Portrait: stored 1920x1080 with a 90° display matrix, shown as 1080x1920.
  "${FF[@]}" -f lavfi -i testsrc2=size=1920x1080:rate=30:duration=2 \
    -f lavfi -i sine=frequency=440:duration=2 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest \
    -metadata:s:v:0 rotate=90 "${OUT}/portrait_tmp.mov"
  "${FF[@]}" -display_rotation 90 -i "${OUT}/portrait_tmp.mov" -c copy \
    "${OUT}/portrait_1080x1920_h264.mov" 2>/dev/null \
    || mv "${OUT}/portrait_tmp.mov" "${OUT}/portrait_1080x1920_h264.mov"
  rm -f "${OUT}/portrait_tmp.mov"

  "${FF[@]}" -f lavfi -i testsrc2=size=640x360:rate=30:duration=2 \
    -f lavfi -i sine=frequency=440:duration=2 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest \
    "${OUT}/small_640x360_h264.mp4"

  "${FF[@]}" -f lavfi -i testsrc2=size=1280x720:rate=30:duration=2 \
    -f lavfi -i sine=frequency=440:duration=2 \
    -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p10le \
    -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
    -x265-params log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc \
    -c:a aac -shortest \
    "${OUT}/hdr_hlg_hevc_10bit.mov"

  printf '1\n00:00:00,000 --> 00:00:01,500\nHello\n' > "${OUT}/subs.srt"
  printf ';FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=Two\n' > "${OUT}/chapters.txt"
  "${FF[@]}" -f lavfi -i testsrc2=size=1280x720:rate=30:duration=2 \
    -f lavfi -i sine=frequency=440:duration=2 \
    -f lavfi -i sine=frequency=660:duration=2 \
    -i "${OUT}/subs.srt" -i "${OUT}/chapters.txt" \
    -map 0:v -map 1:a -map 2:a -map 3:s -map_metadata 4 -map_chapters 4 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -c:s srt -shortest \
    "${OUT}/multitrack.mkv"
  rm -f "${OUT}/subs.srt" "${OUT}/chapters.txt"

  "${FF[@]}" -f lavfi -i sine=frequency=440:duration=3:sample_rate=44100 \
    -c:a flac -sample_fmt s16 "${OUT}/sine_44k_16bit.flac"
  "${FF[@]}" -f lavfi -i sine=frequency=440:duration=3:sample_rate=48000 \
    -ac 2 -c:a pcm_s24le "${OUT}/sine_48k_24bit.wav"
  # Broadband audio so encoders actually need their target bitrate.
  "${FF[@]}" -f lavfi -i anoisesrc=color=pink:duration=4:sample_rate=48000:amplitude=0.4 \
    -ac 2 -c:a pcm_s16le "${OUT}/noise_48k_stereo.wav"
else
  skip "video/audio fixtures" ffmpeg
fi

if have magick; then
  magick -size 256x256 xc:none -fill 'rgba(255,0,0,1)' -draw 'circle 128,128 128,40' \
    "PNG32:${OUT}/transparent_256.png"
  magick -size 12000x10000 xc:'#3366cc' "${OUT}/huge_12000x10000.png"
  magick -size 400x300 xc:'#cc6633' "${OUT}/same_name/photo.png"
  magick -size 400x300 xc:'#33cc66' "${OUT}/same_name/photo_src.jpg"
  magick -size 640x480 gradient:'#ffcc00-#0066ff' "${OUT}/gps_src.jpg"
else
  skip "image fixtures" magick
fi

if [[ -f "${OUT}/same_name/photo_src.jpg" ]]; then
  sips -s format heic "${OUT}/same_name/photo_src.jpg" --out "${OUT}/same_name/photo.heic" >/dev/null
  rm -f "${OUT}/same_name/photo_src.jpg"
fi

if [[ -f "${OUT}/gps_src.jpg" ]]; then
  if have exiftool; then
    exiftool -q -overwrite_original -GPSLatitude=37.3349 -GPSLatitudeRef=N \
      -GPSLongitude=122.0090 -GPSLongitudeRef=W "${OUT}/gps_src.jpg"
    mv "${OUT}/gps_src.jpg" "${OUT}/gps.jpg"
  else
    skip "gps.jpg" exiftool
    rm -f "${OUT}/gps_src.jpg"
  fi
fi

echo "Fixtures written to ${OUT}"
