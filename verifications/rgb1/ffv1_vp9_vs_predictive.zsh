#!/bin/zsh
# =====================================================================
# ffv1_vp9_vs_predictive.zsh -- how close does YCoCg-R + MED + planar get to
# the lossless codecs it borrows from?
# ffv1_vp9_vs_predictive.zsh -- YCoCg-R + MED + planar 與其借鏡的無損編碼器
# 相比，差距還有多少？
#
# The predictive stack uses FFV1's own techniques (MED prediction, YCoCg-R,
# planar layout) but stops short of FFV1's range coder, substituting zstd. This
# measures what that substitution costs, and includes VP9 lossless as the
# streaming-codec reference point.
# 預測式堆疊採用 FFV1 自身的技術（MED 預測、YCoCg-R、planar 排列），但未使用
# FFV1 的 range coder，改以 zstd 替代。本測試量化該替換的代價，並納入 VP9
# lossless 作為串流編碼器的參考點。
#
# All arms are INTRA-only and single-frame, because the stack being compared has
# no inter-frame mode: swift_tar_DOE's predictive preset is YCoCg-R + MED +
# planar, all of which are within-frame. Giving FFV1 and VP9 inter-frame modes
# would compare a video codec against a still-image pipeline.
# 所有組別皆為 INTRA、單影格，因為受比較的堆疊本身沒有影格間模式：
# swift_tar_DOE 的 predictive 預設為 YCoCg-R + MED + planar，三者皆為格內處理。
# 若讓 FFV1 與 VP9 使用影格間模式，等於拿視訊編碼器與靜態影像管線相比。
#
# Usage / 用法:
#   ./ffv1_vp9_vs_predictive.zsh [sample-dir]
#   the corpus is now sample_consecutive (48 consecutive frames from mid-video);
#   sample/ opened on a fade from black that dragged every average down.
#   語料現為 sample_consecutive（自影片中段取的 48 格連續影格）；sample/ 的開頭
#   是自黑畫面淡入的那格，會拉低所有平均值。
# =====================================================================
set -euo pipefail

HERE="${0:A:h}"
SAMPLES="${1:-$HERE/sample}"
DOE="$HERE/swift_tar_DOE"
OUTPUT="$HERE/ffv1_vp9_vs_predictive_output.txt"
HEADER=876

command -v ffmpeg >/dev/null || { echo "[Error] ffmpeg required / 需要 ffmpeg" >&2; exit 1 }
[[ -x "$DOE" ]] || { echo "[Error] build first: swiftc -O swift_tar_DOE.swift -o swift_tar_DOE" >&2; exit 1 }
frames=("$SAMPLES"/*.rgb1(N))
(( ${#frames} )) || { echo "[Error] no samples in $SAMPLES / 找不到樣本" >&2; exit 1 }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ffv1doe.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM
exec > >(tee "$OUTPUT") 2>&1

# Dimensions come from the first container's header (offsets 4 and 8, BE32).
# 尺寸取自第一個容器的標頭（offset 4 與 8，BE32）。
W=$(od -An -tu4 -N4 -j4 --endian=big "${frames[1]}" 2>/dev/null | tr -d ' ') || \
    W=$(python3 -c "print(int.from_bytes(open('${frames[1]}','rb').read(8)[4:8],'big'))")
H=$(python3 -c "print(int.from_bytes(open('${frames[1]}','rb').read(12)[8:12],'big'))")

echo "[Info] date / 日期: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "[Info] os / 系統: macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "[Info] samples / 樣本: ${#frames} frames, ${W}x${H}, intra-only"
echo "[Info] ffmpeg: $(ffmpeg -version 2>/dev/null | head -1)"
echo

raw_total=0; ffv1_total=0; vp9_total=0
printf "%-16s %12s %12s %12s\n" "frame" "raw(B)" "ffv1(B)" "vp9-ll(B)"
printf "%-16s %12s %12s %12s\n" "----------------" "------------" "------------" "------------"

for f in "${frames[@]}"; do
    # Strip the RGB1 header to get the bare rgb24 payload ffmpeg expects.
    # 去掉 RGB1 標頭，取得 ffmpeg 所需的純 rgb24 payload。
    tail -c +$((HEADER + 1)) "$f" > "$TMP/f.rgb24"
    raw=$(stat -f '%z' "$TMP/f.rgb24")

    ffmpeg -v error -f rawvideo -pix_fmt rgb24 -s "${W}x${H}" -i "$TMP/f.rgb24" \
           -c:v ffv1 -level 3 -frames:v 1 "$TMP/f.mkv" -y
    ffv1=$(stat -f '%z' "$TMP/f.mkv")

    ffmpeg -v error -f rawvideo -pix_fmt rgb24 -s "${W}x${H}" -i "$TMP/f.rgb24" \
           -c:v libvpx-vp9 -lossless 1 -pix_fmt gbrp -frames:v 1 "$TMP/f.webm" -y
    vp9=$(stat -f '%z' "$TMP/f.webm")

    # Both must decode back to the original bytes, or the size means nothing.
    # 兩者都必須能解回原始位元組，否則大小毫無意義。
    ffmpeg -v error -i "$TMP/f.mkv" -pix_fmt rgb24 -f rawvideo "$TMP/back.rgb24" -y
    cmp -s "$TMP/f.rgb24" "$TMP/back.rgb24" || { echo "[Error] FFV1 not lossless on ${f:t}" >&2; exit 1 }
    ffmpeg -v error -i "$TMP/f.webm" -pix_fmt rgb24 -f rawvideo "$TMP/back.rgb24" -y
    cmp -s "$TMP/f.rgb24" "$TMP/back.rgb24" || { echo "[Error] VP9 -lossless not lossless on ${f:t}" >&2; exit 1 }

    raw_total=$((raw_total + raw)); ffv1_total=$((ffv1_total + ffv1)); vp9_total=$((vp9_total + vp9))
    printf "%-16s %12d %12d %12d\n" "${f:t}" "$raw" "$ffv1" "$vp9"
    rm -f "$TMP/f.mkv" "$TMP/f.webm"
done

echo
echo "[OK] every FFV1 and VP9 frame decoded back to identical bytes"
echo "[OK] 每個 FFV1 與 VP9 影格皆解回相同位元組"
echo

# Our stack, measured by the same tool on the same frames.
# 我們的堆疊，以相同工具在相同影格上量測。
echo "== YCoCg-R + MED + planar + zstd-19 =="
"$DOE" --preset raw --preset predictive --codec zstd --level 19 --csv "${frames[@]}" \
    > "$TMP/doe.csv"
cat "$TMP/doe.csv"
echo

python3 - "$TMP/doe.csv" "$raw_total" "$ffv1_total" "$vp9_total" "${#frames}" <<'PY'
import csv, sys
path, raw, ffv1, vp9, n = sys.argv[1], *map(int, sys.argv[2:])
rows = {r["variant"]: int(r["compressed_bytes"]) for r in csv.DictReader(open(path))}
ours = rows.get("ycocg-r+med+planar", 0)

print("== Average per frame / 每格平均 ==")
print(f"{'arm':<34}{'bytes':>14}{'of raw':>10}{'vs FFV1':>12}")
print("-" * 70)
for label, total in (("raw payload + zstd-19", rows.get("raw", 0)),
                     ("YCoCg-R + MED + planar + zstd-19", ours),
                     ("VP9 -lossless (intra)", vp9),
                     ("FFV1 level 3 (intra)", ffv1)):
    pct = 100 * total / raw
    rel = total / ffv1 if ffv1 else 0
    print(f"{label:<34}{total/n:>14,.0f}{pct:>9.2f}%{rel:>11.2f}x")

print()
print("== Verdict / 結論 ==")
print(f"  ours vs FFV1 : {100*(ours-ffv1)/ffv1:+.1f}%  "
      f"({100*ffv1/ours:.0f}% of FFV1's efficiency / 達 FFV1 效率的 {100*ffv1/ours:.0f}%)")
print(f"  ours vs VP9  : {100*(ours-vp9)/vp9:+.1f}%")
print(f"  FFV1 vs VP9  : {100*(ffv1-vp9)/vp9:+.1f}%")
PY

echo
echo "[Done] output / 輸出: $OUTPUT"
