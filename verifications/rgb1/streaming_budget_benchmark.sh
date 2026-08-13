#!/bin/zsh
# =====================================================================
# streaming_budget_benchmark.sh -- does the predictive stack fit a 30/60 fps
# frame budget once slices are compressed in parallel?
# streaming_budget_benchmark.sh -- 預測式堆疊在 slice 平行壓縮後，能否塞進
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
#   ./streaming_budget_benchmark.sh [sample-dir] [zstd-level]
# =====================================================================
set -euo pipefail

HERE="${0:A:h}"
SAMPLES="${1:-$HERE/sample}"
LEVEL="${2:-3}"
DOE="$HERE/swift_tar_DOE"
CSV="$HERE/comparison.csv"
OUTPUT="$HERE/streaming_budget_benchmark_output.txt"

# Three frames are enough: --repeat 3 takes a best-of, and the per-frame figures
# are stable to within a few percent across the corpus.
# 三格已足夠：--repeat 3 取最佳值，且各格數字在整份語料上的差異僅數個百分點。
TIMING_FRAMES=("$SAMPLES"/t000020s.rgb1 "$SAMPLES"/t000030s.rgb1 "$SAMPLES"/t000040s.rgb1)
ALL_FRAMES=("$SAMPLES"/*.rgb1(N))

[[ -x "$DOE" ]] || {
    echo "[Error] build first / 請先建置:" >&2
    echo "  swiftc -O swift_tar_DOE.swift -o swift_tar_DOE -L\"\$(brew --prefix)/lib\" -lzstd" >&2
    exit 1
}
(( ${#ALL_FRAMES} )) || {
    echo "[Error] no samples in $SAMPLES / 找不到樣本" >&2
    echo "        generate them: ./rgb1_sampler <video> 10 sample" >&2
    exit 1
}
for f in "${TIMING_FRAMES[@]}"; do
    [[ -f "$f" ]] || { echo "[Error] missing timing frame: $f" >&2; exit 1 }
done

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
for spec in 1:1 20:1 10:10 20:20 40:20; do
    slices="${spec%%:*}"; threads="${spec##*:}"
    for preset in raw predictive; do
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
for r in rows:
    e, d = float(r["encode_ms_per_frame"]), float(r["decode_ms_per_frame"])
    r["total_ms_per_frame"] = f"{e + d:.2f}"
    r["fits_30fps_decode"] = "yes" if d <= BUDGET["30 fps"] else "no"
    r["fits_60fps_decode"] = "yes" if d <= BUDGET["60 fps"] else "no"

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
base = {r["variant"].replace("+slice20", "").replace("slice20", "raw"): r
        for r in rows if r["threads"] == "1" and "slice20" in r["variant"]}
print()
print("== Concurrency speed-up vs the same slicing at -n 1 / 相同切片下的並行加速 ==")
for r in rows:
    key = r["variant"].replace("+slice20", "").replace("+slice10", "") \
                      .replace("+slice40", "").replace("slice10", "raw") \
                      .replace("slice20", "raw").replace("slice40", "raw")
    b = base.get(key)
    if not b or r["threads"] == "1":
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
