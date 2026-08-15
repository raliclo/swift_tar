#!/bin/zsh
# =====================================================================
# streaming_budget_benchmark.zsh -- does the predictive stack fit a 30/60 fps
# frame budget once slices are compressed in parallel?
# streaming_budget_benchmark.zsh -- 預測式堆疊在 slice 平行壓縮後，能否塞進
# 30/60 fps 的影格預算？
#
# A frame budget is per side: the server encodes, the client decodes, and they
# are different machines. So encode and decode are timed separately and each is
# judged against the budget on its own -- their sum is not the constraint.
# 影格預算是分邊計算的：伺服器編碼、客戶端解碼，兩者是不同機器。故編碼與解碼
# 分開計時並各自對照預算判定 —— 兩者之和並非約束條件。
#
# Timing is memory-only. swift_tar_DOE loads every frame before starting its
# clock, and zstd is called in-process through the same libzstd swift_tar links
# (-lzstd), so neither SSD reads nor subprocess spawns are inside the numbers.
# 計時為純記憶體。swift_tar_DOE 在啟動計時前即載入所有影格，且 zstd 以行程內
# 方式呼叫 swift_tar 所連結的同一份 libzstd（-lzstd），故 SSD 讀取與子行程啟動
# 皆不在數字之內。
#
# Correctness is checked separately from timing: --verify compares the decoded
# bytes inside the timed region, which would inflate the decode figure, so the
# sweep runs --no-verify and a full-corpus verification pass runs afterwards.
# 正確性與計時分開檢查：--verify 的位元組比對位於計時區內，會灌大解碼數字，故
# 掃描以 --no-verify 執行，之後再對整份語料做一次驗證。
#
# Usage / 用法:
#   ./streaming_budget_benchmark.zsh [sample-dir] [zstd-level]
# =====================================================================
set -euo pipefail

HERE="${0:A:h}"
SAMPLES="${1:-$HERE/sample_consecutive}"
LEVEL="${2:-3}"
DOE="$HERE/swift_tar_DOE"
CSV="$HERE/comparison.csv"
OUTPUT="$HERE/streaming_budget_benchmark_output.txt"

# Timing runs over the whole corpus. It used to run over three frames named by
# hand, which coupled the numbers to one sampler's naming scheme and left the
# question of whether those three were representative permanently open. The
# corpus is small enough that timing all of it costs a few minutes, so the
# question is better closed than argued.
# 計時涵蓋整份語料。先前是對三個手動指定檔名的影格計時，這既把數字綁死在某一支
# sampler 的命名規則上，也讓「那三格是否具代表性」永遠懸而未決。語料規模夠小，
# 全部計時只需數分鐘，與其爭論不如直接消除這個問題。
ALL_FRAMES=("$SAMPLES"/*.rgb1(N))
TIMING_FRAMES=("${ALL_FRAMES[@]}")

[[ -x "$DOE" ]] || {
    echo "[Error] build first / 請先建置:" >&2
    echo "  swiftc -O swift_tar_DOE.swift -o swift_tar_DOE -L\"\$(brew --prefix)/lib\" -lzstd" >&2
    exit 1
}
(( ${#ALL_FRAMES} )) || {
    echo "[Error] no samples in $SAMPLES / 找不到樣本" >&2
    echo "        generate them: ./make_consecutive_corpus.zsh" >&2
    exit 1
}

exec > >(tee "$OUTPUT") 2>&1

echo "[Info] date / 日期: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "[Info] os / 系統: macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "[Info] cores / 核心: $(sysctl -n hw.perflevel0.logicalcpu)P + $(sysctl -n hw.perflevel1.logicalcpu)E = $(sysctl -n hw.logicalcpu) logical"
echo "[Info] codec: zstd -$LEVEL, in-process libzstd"
echo "[Info] timing frames / 計時影格: ${#TIMING_FRAMES}, corpus / 語料: ${#ALL_FRAMES}"
echo

# ---------------------------------------------------------------------
# Sweep. -n 1 rows are the sequential baseline the speed-ups are measured from.
# 掃描。-n 1 各列為序列基準，加速比以其為分母。
# ---------------------------------------------------------------------
echo "variant,frames,stored_bytes,compressed_bytes,pct_of_raw,encode_ms_per_frame,decode_ms_per_frame,codec,level,slices,threads" > "$CSV"
# Every concurrent configuration has a matching -n 1 row at the same slice count.
# Without 10:1 and 40:1 the speed-ups for slices=10 and slices=40 were divided by
# the slices=20 serial baseline, folding the effect of slicing back into a figure
# whose whole purpose was to exclude it.
# 每個並行組態都有相同 slice 數的 -n 1 對照列。缺少 10:1 與 40:1 時，slices=10 與
# slices=40 的加速比會被除以 slices=20 的序列基準，等於把切片效果摻回一個本意就是
# 要排除它的數值裡。
for spec in 1:1 10:1 20:1 40:1 10:10 20:20 40:20; do
    slices="${spec%%:*}"; threads="${spec##*:}"
    for preset in raw predictive delta delta+predictive; do
        echo "[Run] preset=$preset slices=$slices -n=$threads" >&2
        "$DOE" --preset "$preset" --codec zstd --level "$LEVEL" \
               --slices "$slices" -n "$threads" --repeat 3 --no-verify --csv \
               "${TIMING_FRAMES[@]}" | tail -n +2 >> "$CSV"
    done
done

# ---------------------------------------------------------------------
python3 - "$CSV" <<'PY'
import csv, sys

BUDGET = {"60 fps": 1000 / 60, "30 fps": 1000 / 30}
rows = list(csv.DictReader(open(sys.argv[1])))
# Space, time and speed in one row each. The wire rate is derived rather than
# left for the reader: bytes and milliseconds answer different questions, and
# the decision this table exists for -- what fits a 60 fps link and budget --
# needs both at once. MB/s uses 10^6, matching the rest of the study.
# 每一列同時給出空間、時間與速度。線路速率由此處導出而非留給讀者自行換算：位元組與
# 毫秒回答的是不同問題，而本表所服務的決策——什麼能同時塞進 60 fps 的線路與預算——需要
# 兩者並陳。MB/s 以 10^6 計，與本研究其餘部分一致。
FPS = 60.0
for r in rows:
    e, d = float(r["encode_ms_per_frame"]), float(r["decode_ms_per_frame"])
    per_frame = int(r["compressed_bytes"]) / max(1, int(r["frames"]))
    r["total_ms_per_frame"] = f"{e + d:.2f}"
    r["wire_bytes_per_frame"] = f"{per_frame:.0f}"
    r["wire_mbps_at_60fps"] = f"{per_frame * 8 * FPS / 1e6:.1f}"
    r["wire_MB_per_s"] = f"{per_frame * FPS / 1e6:.1f}"
    r["fits_30fps_decode"] = "yes" if d <= BUDGET["30 fps"] else "no"
    r["fits_60fps_decode"] = "yes" if d <= BUDGET["60 fps"] else "no"
    # 118 MB/s is the practical-gigabit figure build_streaming_budget.py uses.
    # 118 MB/s 為 build_streaming_budget.py 所採用的實務 gigabit 值。
    r["fits_1gbe"] = "yes" if per_frame * FPS / 1e6 <= 118.0 else "no"

w = csv.DictWriter(open(sys.argv[1], "w", newline=""), fieldnames=list(rows[0].keys()))
w.writeheader(); w.writerows(rows)

print("== Per-frame cost / 每格成本 ==")
print(f"{'variant':<30}{'slices':>7}{'-n':>4}{'enc ms':>9}{'dec ms':>9}{'of raw':>9}")
print("-" * 68)
for r in rows:
    print(f"{r['variant']:<30}{r['slices']:>7}{r['threads']:>4}"
          f"{float(r['encode_ms_per_frame']):>9.2f}{float(r['decode_ms_per_frame']):>9.2f}"
          f"{float(r['pct_of_raw']):>8.2f}%")

print()
print("== Against the frame budget / 對照影格預算 ==")
print("   encode is the server's cost, decode the client's; each is judged alone")
print("   編碼為伺服器成本、解碼為客戶端成本；兩者各自判定")
print(f"{'variant':<30}{'-n':>4}{'60 fps (16.67)':>18}{'30 fps (33.33)':>18}")
print("-" * 70)
for r in rows:
    if r["variant"].startswith("raw") and r["threads"] == "1":
        continue
    d = float(r["decode_ms_per_frame"])
    m60 = f"{'PASS' if d <= BUDGET['60 fps'] else 'FAIL'} ({d:.1f} ms)"
    m30 = f"{'PASS' if d <= BUDGET['30 fps'] else 'FAIL'} ({d:.1f} ms)"
    print(f"{r['variant']:<30}{r['threads']:>4}{m60:>18}{m30:>18}")

# Speed-up is reported against the same slice count run sequentially, so it
# isolates concurrency from the effect of slicing itself.
# 加速比以相同 slice 數的序列執行為分母，藉此把並行效果與切片本身的影響分開。
# Pair on (preset, slice count). The earlier version normalised slice10, slice20
# and slice40 onto one key, so every concurrent row divided by whichever serial
# row happened to be present. A row with no exact match is skipped rather than
# silently paired with the wrong denominator.
# 以 (preset, slice 數) 配對。先前版本把 slice10、slice20、slice40 正規化為同一個
# key，導致每個並行列都除以碰巧存在的那個序列列。找不到精確配對的列會略過，而非
# 靜默地與錯誤的分母配對。
def arm_key(row):
    v = row["variant"]
    preset = "predictive" if v.startswith("ycocg") else "raw"
    return (preset, row["slices"])

base = {arm_key(r): r for r in rows if r["threads"] == "1"}
print()
print("== Concurrency speed-up vs the same slicing at -n 1 / 相同切片下的並行加速 ==")
for r in rows:
    if r["threads"] == "1":
        continue
    b = base.get(arm_key(r))
    if not b:
        print(f"  {r['variant']:<30} -n {r['threads']:<3} "
              f"no -n 1 row at slices={r['slices']} / 缺對照，略過")
        continue
    se = float(b["encode_ms_per_frame"]) / float(r["encode_ms_per_frame"])
    sd = float(b["decode_ms_per_frame"]) / float(r["decode_ms_per_frame"])
    print(f"  {r['variant']:<30} -n {r['threads']:<3} encode {se:>5.1f}x  decode {sd:>5.1f}x")
PY

# ---------------------------------------------------------------------
# Correctness, on the full corpus, outside the timed region.
# 正確性驗證，對整份語料執行，位於計時區之外。
# ---------------------------------------------------------------------
echo
echo "== Round-trip verification / 往返驗證 =="
for spec in 20:20 40:20; do
    slices="${spec%%:*}"; threads="${spec##*:}"
    if "$DOE" --preset predictive --codec zstd --level "$LEVEL" \
              --slices "$slices" -n "$threads" --verify --csv "${ALL_FRAMES[@]}" >/dev/null 2>&1; then
        echo "  slices=$slices -n=$threads : PASS — ${#ALL_FRAMES} frames byte-identical / 影格位元組完全一致"
    else
        echo "  slices=$slices -n=$threads : FAIL" >&2
        exit 1
    fi
done

echo
echo "[Done] csv / 表格: $CSV"
echo "[Done] output / 輸出: $OUTPUT"
