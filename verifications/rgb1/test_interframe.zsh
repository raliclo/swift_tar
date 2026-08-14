#!/bin/zsh
# =====================================================================
# test_interframe.zsh -- what inter-frame coding is worth, and to which format.
# test_interframe.zsh -- 影格間編碼的價值，以及它對哪一種格式有利。
#
# Opened three gaps that the 2026-08-14 corpus correction left behind:
# 補上 2026-08-14 語料更正後留下的三個缺口：
#
#   A. NV12 has never been measured with a delta. rgb1/FAQ.md compares RGB1's
#      inter-frame result against NV12's intra-only one, which is the same
#      apples-to-oranges error the corpus correction was about, in the opposite
#      direction. Both formats are measured here by one code path.
#      NV12 從未量過差分。rgb1/FAQ.md 拿 RGB1 的影格間結果對照 NV12 的純 intra
#      結果，正是語料更正所針對的那種不對等比較，只是方向相反。此處兩種格式走
#      同一條程式路徑。
#
#   B. The delta was measured only on continuous footage, where it is at its
#      best. Nothing bounded the worst case. A corpus sampled 10 s apart makes
#      every frame effectively a scene cut, which is that bound.
#      差分只在連續影格上量過，那是它最有利的情形，最壞情況則毫無界定。相隔
#      10 秒取樣的語料使每一格實質上都是鏡頭切換，即為該上界。
#
#   C. The XOR, x264-lossless and VP9-lossy rows were withdrawn from the
#      inter-frame table when their t=0 numbers were retired, and never
#      re-measured.
#      XOR、x264-lossless 與 VP9-lossy 三列在其 t=0 數字退役時自影格間表格撤下，
#      之後未再量測。
#
# Sizes only. Timing is deliberately absent: the 16.67 ms budget is a constraint
# on the client that displays the frame, which is macOS/Metal, and it is measured
# by streaming_budget_benchmark.zsh. Sizes are portable -- zstd -3 and -9 on one
# 1080p frame produce byte-identical output on macOS and on aarch64 Linux -- so
# this needs to run on one platform only.
# 僅量體積。刻意不含計時：16.67 ms 預算是對「顯示該影格的客戶端」的約束，而該端為
# macOS/Metal，計時由 streaming_budget_benchmark.zsh 負責。體積可跨平台共用——同一張
# 1080p 影格經 zstd -3 與 -9 在 macOS 與 aarch64 Linux 上產出位元組完全相同——故本腳本
# 只需在單一平台執行。
#
# Usage / 用法:
#   ./test_interframe.zsh [source-video] [frame-count]
# =====================================================================
set -euo pipefail

HERE="${0:A:h}"
DOE="$HERE/swift_tar_DOE"
OUTPUT="$HERE/test_interframe_output.txt"
DEFAULT_SRC="/Volumes/Windows/proj_Win/swift-cross-ui/testapp/output/20260803 回到神面前 讓神來醫治 [恩典365 - 時代先知 ： 耶利米 系列] [d-t779PY_S0].webm"
SRC="${1:-$DEFAULT_SRC}"
FRAMES="${2:-48}"
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"

for tool in ffmpeg ffprobe zstd python3; do
    command -v "$tool" >/dev/null || { print -ru2 -- "[Error] $tool required / 需要 $tool"; exit 1 }
done
python3 -c "import numpy" 2>/dev/null || { print -ru2 -- "[Error] python3 numpy required / 需要 numpy"; exit 1 }
[[ -x "$DOE" ]] || { print -ru2 -- "[Error] build swift_tar_DOE first / 請先建置 swift_tar_DOE"; exit 1 }
[[ -f "$SRC" ]] || { print -ru2 -- "[Error] source not found: $SRC"; exit 1 }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/interframe.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$SRC")
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$SRC")
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SRC")
START="${START:-$(python3 -c "print(f'{float('$DUR')/2:.1f}')")}"

# Continuous frames from mid-video, and the same count spread across the whole
# clip. The second set is the worst case for a delta: nothing carries over
# between frames.
# 中段的連續影格，以及同樣格數但散佈於全片的取樣。後者是差分的最壞情況：影格之間
# 沒有任何內容可以沿用。
#
# A fixed 5 s apart, not a spacing derived from the frame count. Deriving it
# keeps both corpora the same size but lets the corpus change character: at a
# high frame count the spacing shrinks until "cut every frame" is no longer a
# cut at all, and the worst-case bound quietly turns into a best case. Fixing
# the interval keeps the corpus definition stable and makes the frame count the
# thing that has to give -- so the clip's length caps the study, visibly.
# 固定相隔 5 秒，而非由格數推導間隔。推導雖能讓兩份語料格數相同，卻會讓語料的性質
# 隨之改變：格數一高，間隔就縮短到「每格皆切換」根本不再是切換，最壞情況的上界會悄悄
# 變成最好情況。固定間隔可保持語料定義不變，改由格數讓步——於是片長成為研究規模的
# 上限，且是看得見的上限。
CUT_INTERVAL="${CUT_INTERVAL:-5}"
MAX_CUT_FRAMES=$(python3 -c "print(int(float('$DUR') // float('$CUT_INTERVAL')))")
(( FRAMES <= MAX_CUT_FRAMES )) || {
    print -ru2 -- "[Error] ${FRAMES} frames at ${CUT_INTERVAL}s apart needs $(( FRAMES * CUT_INTERVAL ))s;"
    print -ru2 -- "        this clip is ${DUR}s, so at most ${MAX_CUT_FRAMES} frames"
    print -ru2 -- "        ${FRAMES} 格、相隔 ${CUT_INTERVAL} 秒需要 $(( FRAMES * CUT_INTERVAL )) 秒素材；"
    print -ru2 -- "        本片長 ${DUR} 秒，最多 ${MAX_CUT_FRAMES} 格"
    exit 1
}
for fmt in nv12 rgb24; do
    ffmpeg -v error -ss "$START" -i "$SRC" -frames:v "$FRAMES" \
           -pix_fmt "$fmt" -f rawvideo "$TMP/cont.$fmt" -y
    ffmpeg -v error -i "$SRC" -vf "fps=1/$CUT_INTERVAL" -frames:v "$FRAMES" \
           -pix_fmt "$fmt" -f rawvideo "$TMP/cut.$fmt" -y
done

# Frame size from the geometry, and every extraction checked against it. ffmpeg
# returns fewer frames than asked when the source runs out, and a short file
# would silently rescale every ratio below.
# 單格大小由幾何推導，並據此檢查每次抽取。素材不足時 ffmpeg 取回的格數會少於要求，
# 而過短的檔案會靜默地改變下方所有比率的基準。
NV12_FB=$(( W * H * 3 / 2 ))
RGB_FB=$(( W * H * 3 ))
for spec in "cont.nv12:$NV12_FB" "cut.nv12:$NV12_FB" "cont.rgb24:$RGB_FB" "cut.rgb24:$RGB_FB"; do
    f="${spec%%:*}"; fb="${spec##*:}"; got=$(( $(stat -f %z "$TMP/$f") / fb ))
    (( got == FRAMES )) || {
        print -ru2 -- "[Error] $f: got $got frames, asked for $FRAMES / 取得 $got 格，要求 $FRAMES 格"
        exit 1
    }
done

exec > >(tee "$OUTPUT") 2>&1

print -- "[Info] date / 日期: $(date '+%Y-%m-%d %H:%M:%S %Z')"
print -- "[Info] os: macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
print -- "[Info] source / 來源: ${SRC:t}  ${W}x${H}"
print -- "[Info] continuous / 連續: ${FRAMES} frames from t=${START}s"
print -- "[Info] cut-every-frame / 每格皆切換: ${FRAMES} frames sampled every ${CUT_INTERVAL}s / 每 ${CUT_INTERVAL} 秒取樣一格"
print -- "[Info] codec: zstd -${ZSTD_LEVEL} (CLI, whole frame, no slicing / 整格、不切片)"
print -- "[Info] ffmpeg: $(ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f1-3)"
print -- ""

# ---------------------------------------------------------------------
# A + B. Format x inter-frame transform x corpus, all through one code path.
# A + B. 格式 × 影格間變換 × 語料，全部走同一條程式路徑。
# ---------------------------------------------------------------------
print -- "== A+B. Inter-frame transform by format and corpus / 依格式與語料的影格間變換 =="
print -- "   ratios are of that format's own raw size; B/frame is what goes on the wire"
print -- "   壓縮比以該格式自身的原始大小為基準；B/frame 才是實際上線的量"
print -- ""
python3 - "$TMP" "$NV12_FB" "$RGB_FB" "$FRAMES" "$ZSTD_LEVEL" <<'PY'
import numpy as np, subprocess, sys
tmp, nv12_fb, rgb_fb, frames, level = sys.argv[1], *map(int, sys.argv[2:])

def zsize(buf):
    return len(subprocess.run(["zstd", f"-{level}", "-c"],
                              input=buf.tobytes(), capture_output=True).stdout)

def arms(a):
    # Frame 0 is stored as-is in both inter-frame arms: there is nothing before
    # it. Charging the delta for a frame it cannot predict would flatter it.
    # 兩種影格間變換的第 0 格都原樣保留：它前面沒有東西。若讓差分不必負擔這一格，
    # 等於為它美化數字。
    d = np.empty_like(a); d[0] = a[0]; d[1:] = a[1:] - a[:-1]
    x = np.empty_like(a); x[0] = a[0]; x[1:] = a[1:] ^ a[:-1]
    return {"none": a, "delta": d, "xor": x}

print(f"{'corpus':<12}{'format':<8}{'transform':<10}{'bytes':>14}{'of raw':>9}{'B/frame':>12}")
print("-" * 65)
rows = {}
for corpus in ("cont", "cut"):
    for fmt, fb in (("nv12", nv12_fb), ("rgb24", rgb_fb)):
        a = np.fromfile(f"{tmp}/{corpus}.{fmt}", dtype=np.uint8).reshape(-1, fb)
        for name, buf in arms(a).items():
            total = sum(zsize(f) for f in buf)
            rows[(corpus, fmt, name)] = total
            print(f"{corpus:<12}{fmt:<8}{name:<10}{total:>14,}"
                  f"{100*total/a.nbytes:>8.2f}%{total/frames:>12,.0f}")
    print()

print("== Verdict / 結論 ==")
for corpus, label in (("cont", "continuous / 連續"), ("cut", "cut every frame / 每格皆切換")):
    nv_n, nv_d = rows[(corpus,"nv12","none")], rows[(corpus,"nv12","delta")]
    rg_n, rg_d = rows[(corpus,"rgb24","none")], rows[(corpus,"rgb24","delta")]
    print(f"  {label}:")
    print(f"    delta saves nv12 {100*(1-nv_d/nv_n):5.1f}%   rgb24 {100*(1-rg_d/rg_n):5.1f}%")
    print(f"    rgb24/nv12 on the wire  intra {rg_n/nv_n:.2f}x   delta {rg_d/nv_d:.2f}x")
    xr = rows[(corpus,"rgb24","xor")]
    print(f"    xor vs delta on rgb24   {100*(xr/rg_d-1):+.1f}%  "
          f"({'worse' if xr>rg_d else 'better'})")
PY
print -- ""

# ---------------------------------------------------------------------
# C. The rows withdrawn from rgb1/FAQ.md when their t=0 numbers were retired.
# C. 於 t=0 數字退役時自 rgb1/FAQ.md 撤下的那幾列。
# ---------------------------------------------------------------------
print -- "== C. Withdrawn rows, re-measured / 撤下各列的重測 =="
print -- "   x264 is lossless (qp 0). The VP9 rows are a bitrate sweep: a rate-targeted"
print -- "   encode returns what it was asked for, so its size is an input, not a result."
print -- "   x264 為無損（qp 0）。VP9 各列為位元率掃描：以位元率為目標的編碼會回傳你所要求"
print -- "   的量，故其大小是輸入而非結果。"
print -- ""
printf "%-24s %14s %9s %s\n" "method" "bytes" "of raw" "kind"
printf "%-24s %14s %9s %s\n" "------------------------" "--------------" "---------" "----"
RGB_TOTAL=$(( RGB_FB * FRAMES ))
# label and kind first, then the ffmpeg arguments. An earlier version took the
# kind as the last positional and it was passed through to ffmpeg, which failed
# every encode and reported "encoder unavailable" for encoders that were present.
# 先給標籤與類別，再給 ffmpeg 參數。先前版本把類別放在最後一個位置參數，於是它被一併
# 傳給 ffmpeg，導致每次編碼都失敗，並對明明存在的編碼器回報「encoder unavailable」。
enc() { # label kind ffmpeg-args... ; reads cont.rgb24
    local label="$1" kind="$2"; shift 2
    local out="$TMP/c.bin" err="$TMP/c.err"
    rm -f "$out"
    if ! ffmpeg -v error -f rawvideo -pix_fmt rgb24 -s "${W}x${H}" -r 60 \
                -i "$TMP/cont.rgb24" "$@" "$out" -y 2>"$err"; then
        printf "%-24s %14s %9s %s\n" "$label" "FAIL" "-" "$(head -1 "$err" | cut -c1-40)"
        return
    fi
    local n=$(stat -f %z "$out")
    printf "%-24s %14s %8.2f%% %s\n" "$label" "$(python3 -c "print(f'{$n:,}')")" \
        "$(python3 -c "print(100*$n/$RGB_TOTAL)")" "$kind"
}
enc "x264 lossless (qp 0)" "lossless" -c:v libx264 -qp 0 -f matroska

# Three bitrates, because one would be read as a measurement. A rate-targeted
# lossy encode returns roughly what it was asked for -- the size is an input,
# not a result -- and printing a single row next to lossless ratios invites the
# reader to conclude that VP9 "achieves" it. The spread makes that visible.
# Note also that rate control cannot average over a clip this short: at 48
# frames and 60 fps this is 0.8 s, and the opening keyframe dominates, so the
# realised bitrate overshoots the target by roughly 1.8x.
# 用三個位元率，因為只印一個會被當成量測結果。以位元率為目標的有損編碼大致會回傳你所
# 要求的量——大小是輸入而非結果——若只印一列並排在無損壓縮比旁邊，會引導讀者以為那是
# VP9「達成」的。列出區間即可讓這件事現形。另須注意，如此短的片段無法讓 rate control
# 取得平均：48 格、60 fps 僅 0.8 秒，開頭的 keyframe 佔比極大，實際位元率約超出目標 1.8 倍。
for b in 500k 2300k 8000k; do
    enc "VP9 lossy ($b)" "lossy, size requested" -c:v libvpx-vp9 -b:v "$b" -f webm
done

print -- ""
print -- "[Done] output / 輸出: $OUTPUT"
