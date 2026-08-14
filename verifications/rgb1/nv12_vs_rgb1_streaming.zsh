#!/bin/zsh
# =====================================================================
# nv12_vs_rgb1_streaming.zsh -- DOE for the open question in rgb1/FAQ.md:
# for a streaming display path, is NV12 or RGB1 the better wire format?
# nv12_vs_rgb1_streaming.zsh -- 針對 rgb1/FAQ.md 未決問題的 DOE：串流顯示路徑
# 該用 NV12 還是 RGB1 作為傳輸格式？
#
# rgb1/FAQ.md states NV12 is ~half the size per pixel and that "general-purpose
# compressors (zstd) don't get the same win from raw RGB". This measures both
# claims on real video frames rather than assuming them.
# rgb1/FAQ.md 指出 NV12 每像素約為一半大小，且「通用壓縮器（zstd）對 raw RGB 得不到
# 同樣的效益」。本測試以真實視訊影格實測這兩項說法，而非直接採信。
#
# Factors / 因子:
#   format  : nv12 (1.5 B/px) vs rgb24 (3 B/px, the RGB1 payload)
#   codec   : none, zstd, gzip, lz4, xz  (via swift_tar)
# Responses / 反應變數:
#   transfer bytes  -- what actually goes over the wire / 實際傳輸位元組
#   encode/decode s -- streaming cost / 串流成本
#   render prep s   -- conversion to RGBA, which P6 requires / 轉成 P6 所需的 RGBA
#
# Render prep is a CPU-side proxy: P6 feeds Metal an Image<RGBA> (w*h*4), so
# both formats must be converted before display. It does NOT include GPU shader
# time, so it under-states NV12's advantage if the YUV->RGB matrix is moved into
# a fragment shader (see rgb1/FAQ.md).
# Render prep 是 CPU 端的代理指標：P6 交給 Metal 的是 Image<RGBA>（w*h*4），
# 故兩種格式顯示前都必須轉換。它不含 GPU shader 時間，因此若把 YUV→RGB 矩陣
# 搬進 fragment shader（見 rgb1/FAQ.md），此指標會低估 NV12 的優勢。
#
# Usage / 用法:
#   ./nv12_vs_rgb1_streaming.zsh [source-video] [frame-count]
# =====================================================================
set -euo pipefail

HERE="${0:A:h}"
ST="${SWIFT_TAR:-${HERE:h:h}/release/swift_tar}"
OUTPUT="$HERE/nv12_vs_rgb1_streaming_output.txt"

# --batch (default) compresses all frames as ONE stream, so the codec dedups
# across frames; --per-frame compresses each frame independently and sums the
# results. Batch flatters the ratio: a streamer cannot wait for the whole batch
# (FRAMES/60 s of latency at 60 fps) and cannot reuse a neighbour it has not
# sent yet. Reporting both makes the
# cross-frame dedup bonus visible instead of silently folding it into a
# per-frame bitrate. --both runs the two and prints the gap.
# --batch（預設）將所有影格壓成「單一」串流，codec 因而能跨格去重；--per-frame
# 則每格獨立壓縮再加總。批次會美化壓縮比：串流器不可能等滿整批（60 fps 下為
# FRAMES/60 秒的延遲），也無法重用尚未送出的鄰格。同時回報兩者，可讓跨格去重的紅利現形，而非悄悄併進每格位元率。
# --both 會執行兩者並印出差額。
# batch_vs_per_frame.zsh covers the same question for zstd -3 across two frame
# sources; this covers all five codecs on one source. Keep both in step.
# batch_vs_per_frame.zsh 以 zstd -3 涵蓋兩種影格來源探討同一問題；此處則以
# 單一來源涵蓋全部五種 codec。兩者結論須保持一致。
MODE="batch"
rest=()
for a in "$@"; do
    case "$a" in
        --batch)     MODE="batch" ;;
        --per-frame) MODE="per-frame" ;;
        --both)      MODE="both" ;;
        *)           rest+=("$a") ;;
    esac
done
set -- "${rest[@]}"
FRAMES="${2:-8}"   # after flag filtering, so a flag is never read as the count


# Default is the P6 test app's real-programme sample (VP9 + Opus, 242 s), not a
# synthetic pattern and not the small file_example clip. Synthetic patterns
# compress to ~3% and make both formats look equally compressible, which hides
# the real difference.
# 預設使用 P6 測試程式的真實節目樣本（VP9 + Opus、242 秒），而非合成圖案，也不用
# 較小的 file_example 片段。合成圖案會壓到約 3%，讓兩種格式看起來同樣可壓縮，
# 反而掩蓋真正的差異。
DEFAULT_SRC="/Volumes/Windows/proj_Win/swift-cross-ui/testapp/output/20260803 回到神面前 讓神來醫治 [恩典365 - 時代先知 ： 耶利米 系列] [d-t779PY_S0].webm"
SRC="${1:-$DEFAULT_SRC}"

for tool in ffmpeg ffprobe; do
    command -v "$tool" >/dev/null || { echo "[Error] $tool required / 需要 $tool" >&2; exit 1 }
done
[[ -x "$ST" ]] || { echo "[Error] build first: ../../compile_tar.sh / 請先建置" >&2; exit 1 }
[[ -f "$SRC" ]] || {
    echo "[Error] source video not found: $SRC" >&2
    echo "        pass one as \$1, or mount the volume holding the P6 sample" >&2
    echo "        請以 \$1 指定，或掛載存放 P6 樣本的磁碟區" >&2
    exit 1
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rgb1doe.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM
exec > >(tee "$OUTPUT") 2>&1

W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$SRC")
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$SRC")

echo "[Info] date / 日期: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "[Info] machine / 機器: $(uname -m), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
echo "[Info] os / 系統: macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "[Info] swift_tar: $("$ST" --version)"
echo "[Info] source / 來源: ${SRC:t}  ${W}x${H}, ${FRAMES} frames"
echo "[Info] render prep = conversion to RGBA (what P6 feeds Metal); excludes GPU shader time"
echo "[Info] render prep = 轉成 RGBA（P6 交給 Metal 的格式）；不含 GPU shader 時間"
echo

# ---------------------------------------------------------------------
# Extract the SAME frames in both formats so the comparison is like-for-like.
# 以相同影格取出兩種格式，確保比較基礎一致。
#
# From mid-video, not t=0. This script had no -ss until 2026-08-14 and so read
# the opening of the clip, which is a fade from black. Every ratio it produced
# was ~7-8% of raw, and on that material RGB1 appeared to compress better than
# NV12 -- the opposite of what real content does. Same defect, same clip, as the
# 122 Mbps figure the bitrate table carried. duration/2 matches
# batch_vs_per_frame.zsh and make_consecutive_corpus.zsh so all three land on
# the same footage.
# 取自影片中段而非 t=0。本腳本在 2026-08-14 之前沒有 -ss，因而讀到片頭的自黑畫面
# 淡入。它產出的每個壓縮比都只有原始大小的約 7-8%，而在該素材上 RGB1 看起來比 NV12
# 更好壓——與真實內容的結果相反。這與位元率表上 122 Mbps 那個數字是同一個缺陷、同一
# 段影片。取 duration/2 與 batch_vs_per_frame.zsh、make_consecutive_corpus.zsh 一致，
# 使三者落在同一段影片上。
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SRC")
START="${START:-$(python3 -c "print(f'{float('$DUR')/2:.1f}')")}"
echo "[Info] start / 起點: t=${START}s (mid-video; t=0 is a fade from black / 中段取樣)"
echo

ffmpeg -v error -ss "$START" -i "$SRC" -frames:v "$FRAMES" -pix_fmt nv12  -f rawvideo "$TMP/f.nv12"  -y
ffmpeg -v error -ss "$START" -i "$SRC" -frames:v "$FRAMES" -pix_fmt rgb24 -f rawvideo "$TMP/f.rgb24" -y

for f in "$TMP/f.nv12" "$TMP/f.rgb24"; do
    [[ -s "$f" ]] || { echo "[Error] no frames extracted at t=${START}s / 未取得影格" >&2; exit 1 }
done

NV12_RAW=$(stat -f '%z' "$TMP/f.nv12")
RGB_RAW=$(stat -f '%z' "$TMP/f.rgb24")
# Per-frame, not the whole extraction. Whether a codec can reference the
# previous frame depends on its dictionary against ONE frame; comparing against
# the total would say no for every codec at any frame count.
# 單格大小，非整批。codec 能否參照前一格，取決於其字典相對「單格」的大小；若拿總和
# 來比，任何 codec 在任何影格數下都會得出「不能」。
NV12_FB=$(( NV12_RAW / FRAMES ))
RGB_FB=$(( RGB_RAW / FRAMES ))
RGBA_BYTES=$(( W * H * 4 * FRAMES ))

echo "== Raw frame sizes / 原始影格大小 =="
printf "  %-8s %12s bytes  %5.2f B/px  %s\n" "nv12"  "$NV12_RAW" \
    "$(python3 -c "print($NV12_RAW/($W*$H*$FRAMES))")" "YUV 4:2:0"
printf "  %-8s %12s bytes  %5.2f B/px  %s\n" "rgb24" "$RGB_RAW" \
    "$(python3 -c "print($RGB_RAW/($W*$H*$FRAMES))")" "RGB1 payload (+876 B header per frame)"
printf "  %-8s %12s bytes  %5.2f B/px  %s\n" "rgba"  "$RGBA_BYTES" 4.0 "what P6 hands to Metal"
echo

now() { perl -MTime::HiRes=time -e 'printf "%.6f", time'; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", b-a}'; }

# ---------------------------------------------------------------------
# Transfer size and streaming cost per codec, through swift_tar.
# 各 codec 經 swift_tar 的傳輸大小與串流成本。
# ---------------------------------------------------------------------
echo "== Transfer size and streaming cost / 傳輸大小與串流成本 =="
printf "%-7s %-8s %13s %8s %10s %10s\n" "format" "codec" "transfer(B)" "of raw" "enc(s)" "dec(s)"
printf "%-7s %-8s %13s %8s %10s %10s\n" "-------" "--------" "-------------" "--------" "----------" "----------"

# per_frame_size: compress each frame as its own stream and sum the results.
# This is what a streamer actually pays -- it cannot wait for the whole batch,
# and cannot reuse a neighbour it has not transmitted yet. The batch figure
# includes cross-frame dedup that no real-time sender can claim.
# per_frame_size：將每格各自壓成獨立串流再加總。這才是串流器真正付出的成本——
# 它不可能等滿整批，也無法重用尚未送出的鄰格。批次數字含有任何即時傳送端都
# 拿不到的跨格去重紅利。
per_frame_size() { # src frame-bytes codec → total compressed bytes
    local src="$1" fb="$2" codec="$3" total=0 i=0 n
    n=$(( $(stat -f '%z' "$src") / fb ))
    local -a flag
    case "$codec" in
        none) flag=() ;;
        *)    flag=(--$codec) ;;
    esac
    while (( i < n )); do
        dd if="$src" of="$TMP/frame.bin" bs="$fb" skip="$i" count=1 2>/dev/null
        "$ST" -c "${flag[@]}" -f "$TMP/frame.arc" -C "$TMP" frame.bin 2>/dev/null || return 1
        total=$(( total + $(stat -f '%z' "$TMP/frame.arc") ))
        (( ++i ))
    done
    print -- "$total"
}

typeset -A BEST BEST_PF BATCH
for fmt in nv12 rgb24; do
    src="$TMP/f.$fmt"
    raw=$(stat -f '%z' "$src")
    for codec in none zstd gzip lz4 xz; do
        arc="$TMP/$fmt.$codec"
        case "$codec" in
            none) flag=() ;;
            *)    flag=(--$codec) ;;
        esac
        s=$(now)
        "$ST" -c "${flag[@]}" -f "$arc" -C "$TMP" "f.$fmt" 2>/dev/null || { echo "  $fmt/$codec SKIP"; continue }
        e=$(now)
        enc=$(elapsed $s $e)
        size=$(stat -f '%z' "$arc")
        rm -rf "$TMP/x"; mkdir -p "$TMP/x"
        s=$(now); "$ST" -x -f "$arc" -C "$TMP/x" 2>/dev/null; e=$(now)
        dec=$(elapsed $s $e)
        cmp -s "$src" "$TMP/x/f.$fmt" || { echo "  [Error] $fmt/$codec round-trip mismatch" >&2; exit 1 }
        printf "%-7s %-8s %13s %7.2f%% %10s %10s\n" "$fmt" "$codec" "$size" \
            "$(python3 -c "print(100*$size/$raw)")" "$enc" "$dec"
        [[ "$codec" == "zstd" ]] && BEST[$fmt]=$size
        BATCH[$fmt,$codec]=$size
    done
done
echo
echo "[OK] every codec round-tripped to identical bytes / 每個 codec 皆還原為相同位元組"

# ---------------------------------------------------------------------
# Per-frame compression: the number a real-time sender can actually claim.
# 逐格壓縮：即時傳送端真正能主張的數字。
# ---------------------------------------------------------------------
if [[ "$MODE" == "per-frame" || "$MODE" == "both" ]]; then
    echo
    echo "== Per-frame compression (each frame its own stream) / 逐格壓縮（每格獨立串流） =="
    printf "%-7s %-8s %13s %8s %13s %10s\n" \
        "format" "codec" "per-frame(B)" "of raw" "batch(B)" "batch adv."
    printf "%-7s %-8s %13s %8s %13s %10s\n" \
        "-------" "--------" "-------------" "--------" "-------------" "----------"
    for fmt in nv12 rgb24; do
        src="$TMP/f.$fmt"
        raw=$(stat -f '%z' "$src")
        case "$fmt" in
            nv12)  fb=$(( W * H * 3 / 2 )) ;;
            rgb24) fb=$(( W * H * 3 )) ;;
        esac
        for codec in none zstd gzip lz4 xz; do
            pf=$(per_frame_size "$src" "$fb" "$codec") || { echo "  $fmt/$codec SKIP"; continue }
            [[ "$codec" == "zstd" ]] && BEST_PF[$fmt]=$pf
            b="${BATCH[$fmt,$codec]:-}"
            if [[ -n "$b" && "$b" -gt 0 ]]; then
                adv=$(python3 -c "print(f'{100*($pf-$b)/$b:+.2f}%')")
            else
                adv="-"; b="-"
            fi
            printf "%-7s %-8s %13s %7.2f%% %13s %10s\n" "$fmt" "$codec" "$pf" \
                "$(python3 -c "print(100*$pf/$raw)")" "$b" "$adv"
        done
    done
    echo
    # The verdict is derived from the run, not asserted. An earlier version had
    # the numbers and the conclusion typed in as prose -- "at most 0.34%",
    # "batching does NOT inflate the per-frame bitrate" -- and both were still
    # printed verbatim by a later run that measured +21.27%. A conclusion that
    # cannot disagree with its own measurement is not a conclusion.
    # 結論由本次執行推導，而非寫死。先前版本把數字與結論直接寫成文字——「最大
    # 0.34%」「批次不會灌大每格位元率」——而在一次量到 +21.27% 的執行中，那兩句
    # 依然被原樣印出。一個無法與自身量測相牴觸的結論，不是結論。
    echo "'batch adv.' is how much larger the per-frame total is than the batch"
    echo "figure -- i.e. the cross-frame dedup a real-time sender cannot use."
    echo "The 'none' rows show the floor: per-frame tar headers, not compression."
    echo "「batch adv.」為逐格加總相對批次數字大出多少，即即時傳送端無法取用的"
    echo "跨格去重紅利。none 各列即為下限：每格的 tar header，與壓縮無關。"
    echo
    printf "%-14s %10s %10s  %s\n" "codec/format" "dict" "dict/frame" "cross-frame reuse possible?"
    printf "%-14s %10s %10s  %s\n" "--------------" "----------" "----------" "---------------------------"
    # Window sizes are the codecs' defaults at the presets swift_tar invokes.
    # zstd -3 and gzip and lz4 all look back less than one 1080p frame, so they
    # cannot reference the previous frame at all. xz's 8 MiB dictionary is
    # LARGER than an NV12 frame -- that case was always outside the window
    # argument, and measurement caught up with it only when the corpus stopped
    # being a fade from black.
    # 各視窗大小為 swift_tar 所用 preset 下的 codec 預設值。zstd -3、gzip 與 lz4 的
    # 回看範圍都小於一張 1080p 影格，故根本無法參照前一格。xz 的 8 MiB 字典則**大於**
    # 一張 NV12 影格——該情形從來就不在視窗論證的涵蓋範圍內，只是直到語料不再是自黑
    # 畫面淡入，量測才追上這件事。
    for spec in "zstd/nv12:1048576:$NV12_FB" "zstd/rgb24:1048576:$RGB_FB" \
                "gzip/*:32768:$NV12_FB" "lz4/*:65536:$NV12_FB" \
                "xz/nv12:8388608:$NV12_FB" "xz/rgb24:8388608:$RGB_FB"; do
        name="${spec%%:*}"; rest="${spec#*:}"; dict="${rest%%:*}"; fb="${rest##*:}"
        ratio=$(python3 -c "print(f'{$dict/$fb:.2f}')")
        verdict=$(python3 -c "print('yes' if $dict > $fb else 'no')")
        printf "%-14s %10s %10s  %s\n" "$name" "$dict" "$ratio" "$verdict"
    done
    echo
    echo "Any row whose dictionary exceeds one frame can reuse the previous"
    echo "frame, and its batch figure is NOT a per-frame bitrate. Quote the"
    echo "per-frame column for those."
    echo "凡字典大於單格的列都能重用前一格，其批次數字不等於每格位元率；該類列請"
    echo "改引用 per-frame 欄。"
fi
echo

# ---------------------------------------------------------------------
# Render prep: both formats must reach RGBA before P6 can display them.
# Render prep：兩種格式都必須先轉成 RGBA，P6 才能顯示。
# ---------------------------------------------------------------------
echo "== Render prep: convert to RGBA / 轉換成 RGBA =="
printf "%-7s %10s %12s %14s\n" "format" "time(s)" "MB/s" "note"
for fmt in nv12 rgb24; do
    src="$TMP/f.$fmt"
    best=99999
    for _ in 1 2 3; do
        s=$(now)
        ffmpeg -v error -f rawvideo -pix_fmt "$fmt" -s "${W}x${H}" -i "$src" \
               -pix_fmt rgba -f rawvideo "$TMP/out.rgba" -y
        e=$(now)
        t=$(elapsed $s $e)
        best=$(awk -v a="$t" -v b="$best" 'BEGIN{print (a<b)?a:b}')
    done
    got=$(stat -f '%z' "$TMP/out.rgba")
    [[ "$got" == "$RGBA_BYTES" ]] || echo "  [Warn] rgba size $got != expected $RGBA_BYTES"
    note=$( [[ "$fmt" == "nv12" ]] && echo "YUV->RGB matrix" || echo "add alpha channel" )
    printf "%-7s %10s %12s %14s\n" "$fmt" "$best" \
        "$(python3 -c "print(f'{$RGBA_BYTES/1e6/$best:.1f}')")" "$note"
done
echo

# ---------------------------------------------------------------------
echo "== Verdict / 結論 =="
python3 - <<PY
nv, rgb = ${BEST[nv12]:-0}, ${BEST[rgb24]:-0}
if nv and rgb:
    small, big = ("NV12", "RGB1") if nv < rgb else ("RGB1", "NV12")
    lo, hi = min(nv, rgb), max(nv, rgb)
    print(f"  zstd transfer: NV12 {nv:,} B vs RGB1 {rgb:,} B")
    print(f"  -> {small} transfers {hi-lo:,} B less ({(hi-lo)/hi*100:.1f}% smaller)")
    print(f"  RGB1 needs {rgb/nv:.2f}x the bytes of NV12 on the wire")
PY
echo
echo "[Done] output / 輸出: $OUTPUT"
