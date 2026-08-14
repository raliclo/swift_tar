#!/bin/zsh
# =====================================================================
# consecutive_bitrate.zsh -- per-frame zstd-3 wire cost for NV12 and RGB24,
# over the same frames every other arm of the study is measured on.
# consecutive_bitrate.zsh -- NV12 與 RGB24 的逐格 zstd-3 線路成本，量測對象與本
# 研究其他組別完全相同的那批影格。
#
# batch_vs_per_frame.zsh already reports a per-frame column, but over 8 frames,
# because its own argument is about 8-frame buffering (133 ms at 60 fps) and
# changing that count would break it. The FAQ's bandwidth table needs the same
# corpus as its FFV1 and predictive rows, which is 48 frames, so it is measured
# here instead.
# batch_vs_per_frame.zsh 已有逐格欄位，但只涵蓋 8 格——它自身的論證正是關於緩衝
# 8 格（60 fps 下 133 ms），改動格數會使該論證失效。FAQ 的頻寬表需要與其 FFV1 和
# predictive 兩列相同的語料，即 48 格，故改由本腳本量測。
#
# RGB24 comes from the RGB1 corpus itself (payload = bare rgb24), so those bytes
# are literally the same ones the other arms compressed. NV12 has no RGB1
# container, so it is re-extracted from the same window of the same source.
# RGB24 直接取自 RGB1 語料本身（payload 即為純 rgb24），故這些位元組與其他組別所
# 壓縮的完全是同一批。NV12 沒有 RGB1 容器，故自同一來源的同一段落重新取出。
#
# Usage / 用法:
#   ./consecutive_bitrate.zsh [source-video] [corpus-dir]
# =====================================================================
set -euo pipefail

HERE="${0:A:h}"
DEFAULT_SRC="/Volumes/Windows/proj_Win/swift-cross-ui/testapp/output/20260803 回到神面前 讓神來醫治 [恩典365 - 時代先知 ： 耶利米 系列] [d-t779PY_S0].webm"
SRC="${1:-$DEFAULT_SRC}"
CORPUS="${2:-$HERE/sample_consecutive}"
OUTPUT="$HERE/consecutive_bitrate_output.txt"
HEADER=876
FPS=60

for tool in ffmpeg ffprobe zstd python3; do
    command -v "$tool" >/dev/null || { print -ru2 -- "[Error] $tool required / 需要 $tool"; exit 1 }
done
[[ -f "$SRC" ]] || { print -ru2 -- "[Error] source not found: $SRC"; exit 1 }
frames=("$CORPUS"/*.rgb1(N))
(( ${#frames} )) || { print -ru2 -- "[Error] no corpus in $CORPUS — run make_consecutive_corpus.zsh"; exit 1 }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cbitrate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM
exec > >(tee "$OUTPUT") 2>&1

W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$SRC")
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$SRC")
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SRC")
MID=$(python3 -c "print(f'{float('$DUR')/2:.1f}')")
N=${#frames}

print -- "[Info] date / 日期: $(date '+%Y-%m-%d %H:%M:%S %Z')"
print -- "[Info] os: $(command -v sw_vers >/dev/null 2>&1 && echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))" || uname -sr)"
print -- "[Info] source / 來源: ${SRC:t}  ${W}x${H}"
print -- "[Info] corpus / 語料: $N consecutive frames from t=${MID}s / 自 t=${MID}s 起的連續影格"
print -- "[Info] link / 線路: 118 MB/s (1 GbE practical, same value build_streaming_budget.py uses)"
print -- "[Info]              118 MB/s（1 GbE 實務值，與 build_streaming_budget.py 相同）"
print -- ""

# RGB24: strip the 876-byte RGB1 header, compress the payload alone.
# RGB24：去掉 876 B 的 RGB1 標頭，僅壓縮 payload。
rgb24_total=0
for f in "${frames[@]}"; do
    sz=$(tail -c +$((HEADER + 1)) "$f" | zstd -3 -c | wc -c | tr -d ' ')
    rgb24_total=$((rgb24_total + sz))
done

# NV12: re-extract the same window. ffmpeg is deterministic here, so this lands
# on the frames the corpus was built from.
# NV12：重新取出同一段落。ffmpeg 在此為確定性行為，故取到的正是語料所本的影格。
ffmpeg -v error -ss "$MID" -i "$SRC" -frames:v "$N" \
       -pix_fmt nv12 -f rawvideo "$TMP/nv12.raw" -y
NV12_FB=$((W * H * 3 / 2))
got=$(( $(stat -f %z "$TMP/nv12.raw") / NV12_FB ))
(( got == N )) || { print -ru2 -- "[Error] nv12: wanted $N frames, got $got"; exit 1 }

nv12_total=0
for ((i = 0; i < N; i++)); do
    sz=$(dd if="$TMP/nv12.raw" bs="$NV12_FB" skip="$i" count=1 2>/dev/null | zstd -3 -c | wc -c | tr -d ' ')
    nv12_total=$((nv12_total + sz))
done

print -- "== Per-frame wire cost at zstd-3 / 逐格線路成本 =="
printf "%-10s %14s %10s %10s %12s\n" "format" "bytes/frame" "MB/s" "Mbps" "of 1 GbE"
printf "%-10s %14s %10s %10s %12s\n" "----------" "--------------" "----------" "----------" "------------"
for pair in "nv12:$nv12_total" "rgb24:$rgb24_total"; do
    fmt="${pair%%:*}"; total="${pair##*:}"
    python3 -c "
b = $total / $N
mbs = b * $FPS / 1e6
print(f'{\"$fmt\":<10} {b:14,.0f} {mbs:10.1f} {b*8*$FPS/1e6:10.1f} {100*mbs/118:11.0f}%')"
done

print -- ""
print -- "[Done] output / 輸出: $OUTPUT"
