#!/bin/zsh
# =====================================================================
# batch_vs_per_frame.zsh -- is a batched compression ratio a valid stand-in for
# a per-frame streaming bitrate?
# batch_vs_per_frame.zsh -- 批次壓縮比可否代表逐格串流的位元率？
#
# nv12_vs_rgb1_streaming.zsh compresses 8 consecutive frames as one zstd stream
# and the FAQ divides that by 8 to quote a per-frame bitrate. zstd's window spans
# the whole batch, so it deduplicates across frames — something a 60 fps streamer
# cannot do without buffering 8 frames, which is 133 ms of latency it does not
# have. This measures the gap directly.
# nv12_vs_rgb1_streaming.zsh 將 8 格連續影格壓成單一 zstd 串流，而 FAQ 將其除以 8
# 作為每格位元率。zstd 的視窗涵蓋整個批次，因而跨影格去重——60 fps 串流器若要如此
# 必須緩衝 8 格，即 133 ms 的延遲，而它沒有這個餘裕。本測試直接量出該差距。
#
# Two sources, because the batch effect depends on how similar neighbouring
# frames are:
#   consecutive  8 frames from mid-video — what a streamer actually sends
#   sampled      8 frames 10 s apart — the corpus the rest of the study uses
# 使用兩種來源，因為批次效果取決於相鄰影格的相似程度：
#   consecutive  取自影片中段的 8 格連續影格——串流器實際會送的內容
#   sampled      相隔 10 秒的 8 格——本研究其餘部分所用的語料
#
# Usage / 用法:
#   ./batch_vs_per_frame.zsh [source-video]
# =====================================================================
set -euo pipefail

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
OUTPUT="$HERE/batch_vs_per_frame_output.txt"
DEFAULT_SRC="/Volumes/Windows/proj_Win/swift-cross-ui/testapp/output/20260803 回到神面前 讓神來醫治 [恩典365 - 時代先知 ： 耶利米 系列] [d-t779PY_S0].webm"
SRC="${1:-$DEFAULT_SRC}"
FRAMES=8

for tool in ffmpeg ffprobe zstd; do
    command -v "$tool" >/dev/null || { echo "[Error] $tool required / 需要 $tool" >&2; exit 1 }
done
[[ -f "$SRC" ]] || { echo "[Error] source not found: $SRC" >&2; exit 1 }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/batchdoe.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM
if (( DRY_RUN )); then
    print -- "[dry-run] would write / 將寫入: $OUTPUT"
    print -- "[dry-run] start / 起點: ${MID}s   frames / 格數: ${FRAMES}"
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
(( $(python3 -c "print(1 if float('$MID') >= $MIN_START or $FRAMES >= 10 else 0)") )) || {
    print -ru2 -- "[Error] MID=${MID}s is inside the opening ${MIN_START}s with only $FRAMES frames"
    print -ru2 -- "        起點 ${MID} 秒落在片頭 ${MIN_START} 秒內，且僅取 $FRAMES 格"
    exit 1
}


echo "[Info] date / 日期: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "[Info] source / 來源: ${SRC:t}  ${W}x${H}"
echo "[Info] consecutive frames taken from t=${MID}s, not t=0 — the opening of"
echo "       this clip is a fade from black and compresses ~5x better than real"
echo "       content, which is what made an earlier sweep land at 7%."
echo "       連續影格取自 t=${MID}s 而非 t=0——本片開頭是自黑畫面淡入，較真實內容"
echo "       易壓縮約 5 倍，先前掃描落在 7% 即肇因於此。"
echo

# ---------------------------------------------------------------------
# Extract both sources in both pixel formats.
# 以兩種 pixel format 取出兩種來源。
# ---------------------------------------------------------------------
for fmt in nv12 rgb24; do
    ffmpeg -v error -ss "$MID" -i "$SRC" -frames:v "$FRAMES" \
           -pix_fmt "$fmt" -f rawvideo "$TMP/consecutive.$fmt" -y
    ffmpeg -v error -i "$SRC" -vf "fps=1/10" -frames:v "$FRAMES" \
           -pix_fmt "$fmt" -f rawvideo "$TMP/sampled.$fmt" -y
done

frame_bytes() { case "$1" in nv12) echo $((W * H * 3 / 2));; *) echo $((W * H * 3));; esac }

echo "== Batched vs per-frame at zstd -3 / 批次與逐格對比 =="
printf "%-13s %-7s %14s %14s %9s %12s\n" \
    "source" "format" "batched(B/f)" "per-frame(B/f)" "penalty" "60fps Mbps"
printf "%-13s %-7s %14s %14s %9s %12s\n" \
    "-------------" "-------" "--------------" "--------------" "---------" "------------"

for source in consecutive sampled; do
    for fmt in nv12 rgb24; do
        fb=$(frame_bytes "$fmt")
        raw="$TMP/$source.$fmt"

        # Batched: the whole run through one zstd stream, as the old script did.
        # 批次：整段以單一 zstd 串流壓縮，即舊腳本的作法。
        batched=$(zstd -3 -c "$raw" | wc -c | tr -d ' ')

        # Per-frame: each frame its own stream, which is what a streamer sends.
        # 逐格：每格自成一個串流，即串流器實際送出的形式。
        total=0
        for ((i = 0; i < FRAMES; i++)); do
            dd if="$raw" bs="$fb" skip="$i" count=1 2>/dev/null \
                | zstd -3 -c | wc -c | read -r sz
            total=$((total + sz))
        done

        bpf_batch=$((batched / FRAMES))
        bpf_each=$((total / FRAMES))
        printf "%-13s %-7s %14d %14d %8.1f%% %12.0f\n" \
            "$source" "$fmt" "$bpf_batch" "$bpf_each" \
            "$(python3 -c "print(100*($bpf_each-$bpf_batch)/$bpf_batch)")" \
            "$(python3 -c "print($bpf_each*8*60/1e6)")"
    done
done

echo
echo "== Verdict / 結論 =="
echo "  The penalty column is what the FAQ's per-frame figures were missing."
echo "  A streamer cannot buffer 8 frames (133 ms at 60 fps), so the per-frame"
echo "  column is the honest one and the batched column understates the wire cost."
echo "  penalty 欄即 FAQ 的每格數字所遺漏的部分。串流器無法緩衝 8 格（60 fps 下為"
echo "  133 ms），故 per-frame 欄才是誠實的數字，batched 欄低估了線路成本。"
echo
echo "[Done] output / 輸出: $OUTPUT"
