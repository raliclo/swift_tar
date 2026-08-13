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
FRAMES="${2:-8}"
OUTPUT="$HERE/nv12_vs_rgb1_streaming_output.txt"

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
# ---------------------------------------------------------------------
ffmpeg -v error -i "$SRC" -frames:v "$FRAMES" -pix_fmt nv12  -f rawvideo "$TMP/f.nv12"  -y
ffmpeg -v error -i "$SRC" -frames:v "$FRAMES" -pix_fmt rgb24 -f rawvideo "$TMP/f.rgb24" -y

NV12_RAW=$(stat -f '%z' "$TMP/f.nv12")
RGB_RAW=$(stat -f '%z' "$TMP/f.rgb24")
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

typeset -A BEST
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
    done
done
echo
echo "[OK] every codec round-tripped to identical bytes / 每個 codec 皆還原為相同位元組"
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
