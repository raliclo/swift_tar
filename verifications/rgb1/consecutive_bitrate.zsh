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

# --help answers before any work starts / --help 在任何工作開始前先回答。
script_path="${0:A}"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,25p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

# --dry-run validates and reports without writing the committed record. Testing
# the sampling guards used to mean running the script for real, and one such
# test overwrote this file's record with data from t=5 s -- the opening the
# guards exist to keep out. A check that damages what it checks is not a check.
# --dry-run 只驗證並回報，不寫入入版紀錄。先前要測試取樣守門就得真的跑一次，而其中一次
# 測試把本檔的紀錄覆蓋成 t=5 秒的資料——正是那些守門要擋掉的片頭。一個會破壞其檢查對象
# 的檢查，不算檢查。
DRY_RUN=0
_args=()
for _a in "$@"; do
    case "$_a" in
        --dry-run) DRY_RUN=1 ;;
        *)         _args+=("$_a") ;;
    esac
done
set -- "${_args[@]}"

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
if (( DRY_RUN )); then
    print -- "[dry-run] would write / 將寫入: $OUTPUT"
    print -- "[dry-run] start / 起點: ${MID}s   frames / 格數: ${N}"
    print -- "[dry-run] validation passed; nothing written / 驗證通過，未寫入任何檔案"
    exit 0
fi

exec > >(tee "$OUTPUT") 2>&1

W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$SRC")
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$SRC")
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SRC")
# Never start inside the opening 30 s, and enforce it hardest when the selection
# is small. A clip's first seconds are where fades, title cards and static holds
# live: the 8 frames taken at t=0 that produced the 122 Mbps bitrate figure
# compressed to 7% of raw where real content gives 50%. A large sample dilutes
# that; a sample under 10 frames is dominated by it.
# 起點一律不落在片頭 30 秒內，且在選取格數少時檢查最嚴。影片開頭正是淡入、標題卡與
# 靜止畫面所在：先前產出 122 Mbps 那個數字的 t=0 八格，壓縮到原始的 7%，而真實內容為
# 50%。樣本大時該影響會被稀釋，樣本少於 10 格時則由它主導。
MIN_START=30
MID=$(python3 -c "print(f'{max(float('$DUR')/2, $MIN_START):.1f}')")
(( $(python3 -c "print(1 if float('$MID') >= $MIN_START or 3 >= 10 else 0)") )) || {
    print -ru2 -- "[Error] MID=${MID}s is inside the opening ${MIN_START}s with only 3 frames"
    print -ru2 -- "        起點 ${MID} 秒落在片頭 ${MIN_START} 秒內，且僅取 3 格"
    exit 1
}

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
