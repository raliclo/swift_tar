#!/usr/bin/env bash
# test_swift_tar_rgb1.sh
# Integration test: an RGB1 container packed by swift_tar must survive a full
# archive round-trip through swift_tar's own tar / gzip / zip pipelines and come
# back byte-for-byte, with --rgb1-info and --rgb1-raw still decoding correctly.
# Also checks interop: the platform's standard tar extracts swift_tar's plain
# tar of the .rgb1 without corrupting it. This complements test_rgb1.sh (which
# unit-tests the three RGB1 modes in isolation).
# 整合測試：swift_tar 打包出的 RGB1 容器，經 swift_tar 自身的 tar / gzip / zip
# 封存往返後，必須位元組級一致，且 --rgb1-info 與 --rgb1-raw 仍能正確解析。
# 另驗證互通：系統標準 tar 能解出 swift_tar 的純 tar .rgb1 而不損壞。此測試補足
# test_rgb1.sh（後者單獨測 RGB1 三個模式）。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${ST:-}" ]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$HERE/release/swift_tar.exe" ;;
    *) ST="$HERE/release/swift_tar" ;;
  esac
fi
SYS_TAR="$(command -v tar)"

if [ ! -x "$ST" ]; then
  echo "error: build first (./compile_tar.sh) — missing $ST" >&2
  exit 1
fi

# Keep the test output log in the script's own folder / 測試輸出 log 保存在腳本同一層資料夾
LOG="$HERE/test_swift_tar_rgb1.log"
exec > >(tee "$LOG") 2>&1

# Temp working dir lives in the same folder, removed when done /
# 暫存工作資料夾建在同一層，測試結束即移除
TMP="$(mktemp -d "$HERE/.test_swift_tar_rgb1.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# Build one reference RGB1 container (4x3 → 36 payload bytes) and its raw
# payload + info snapshot to compare extracted copies against.
# 建立一個參考 RGB1 容器（4×3 → 36 payload bytes），連同 raw payload 與 info
# 快照，供解出後比對。
# ---------------------------------------------------------------------------
SRC="$TMP/src"; mkdir -p "$SRC"
RAW="$TMP/img.rgb"
# 36 deterministic bytes / 36 個決定性位元組
printf 'The quick brown fox jumps over lazyy' > "$RAW"   # 36 bytes
[ "$(wc -c < "$RAW" | tr -d ' ')" -eq 36 ] || { echo "internal: RAW not 36 bytes"; exit 2; }

"$ST" --rgb1-pack --width 4 --height 3 \
      --lat 25.0334567 --lng 121.5678901 --height-m 12.345 \
      --title "Integration" --country "Taiwan" \
      --creator-email "photog@example.com" --right "CcBy" \
      --created-ms 1700000000123 --tz-offset-min 480 \
      -f "$SRC/img.rgb1" "$RAW"

REF_INFO="$TMP/ref.info"
"$ST" --rgb1-info -f "$SRC/img.rgb1" > "$REF_INFO"

# verify_extract: given an extraction dir, the .rgb1 there must be identical to
# the source, its info must match the reference, and its stripped payload must
# match the original raw bytes. / 驗證解出：該目錄的 .rgb1 須與來源相同、info
# 與參考一致、去 header 後的 payload 與原始 raw 一致。
verify_extract() { # label dir
  local label="$1" dir="$2" f="$2/img.rgb1"
  if [ ! -f "$f" ]; then bad "$label: extracted img.rgb1 missing"; return; fi
  if ! cmp -s "$SRC/img.rgb1" "$f"; then bad "$label: extracted .rgb1 differs byte-wise"; return; fi
  if ! diff -q "$REF_INFO" <("$ST" --rgb1-info -f "$f") >/dev/null; then
    bad "$label: --rgb1-info on extracted .rgb1 differs"; return; fi
  if ! cmp -s "$RAW" <("$ST" --rgb1-raw -f "$f"); then
    bad "$label: --rgb1-raw payload differs"; return; fi
  ok "$label: .rgb1 survived round-trip (bytes + info + payload)"
}

# ---------------------------------------------------------------------------
# 1) Round-trip through each swift_tar archive codec.
#    透過 swift_tar 各封存 codec 往返。
#    "plain" = no codec flag; others exercise the filter pipeline.
# ---------------------------------------------------------------------------
roundtrip() { # label codec-flag archive-name
  local label="$1" flag="$2" arc="$TMP/$3" out="$TMP/x_$3"
  mkdir -p "$out"
  if [ -n "$flag" ]; then
    "$ST" -c "$flag" -f "$arc" -C "$SRC" img.rgb1
  else
    "$ST" -c        -f "$arc" -C "$SRC" img.rgb1
  fi
  "$ST" -x -f "$arc" -C "$out"
  verify_extract "$label" "$out"
}

roundtrip "tar (plain)" ""       "a.tar"
roundtrip "gzip"        "--gzip" "a.tar.gz"
roundtrip "zstd"        "--zstd" "a.tar.zst"
roundtrip "zip"         "--zip"  "a.zip"

# ---------------------------------------------------------------------------
# 2) Interop: system tar extracts swift_tar's plain tar of the .rgb1 intact.
#    互通：系統 tar 解出 swift_tar 的純 tar .rgb1，內容完好。
# ---------------------------------------------------------------------------
mkdir -p "$TMP/x_interop"
"$SYS_TAR" -x -f "$TMP/a.tar" -C "$TMP/x_interop"
verify_extract "interop (system tar extracts swift_tar tar)" "$TMP/x_interop"

# ---------------------------------------------------------------------------
# 3) Reverse interop: swift_tar extracts a .rgb1 archived by system tar.
#    反向互通：swift_tar 解出由系統 tar 封存的 .rgb1。
# ---------------------------------------------------------------------------
"$SYS_TAR" -c -f "$TMP/sys.tar" -C "$SRC" img.rgb1
mkdir -p "$TMP/x_rev"
"$ST" -x -f "$TMP/sys.tar" -C "$TMP/x_rev"
verify_extract "reverse interop (swift_tar extracts system tar)" "$TMP/x_rev"

# ---------------------------------------------------------------------------
# 4) Codec comparison: pack a larger, moderately-compressible RGB1 image
#    (1024x1024 → 3 MiB payload) and report each swift_tar codec's archive
#    size, compression ratio, and create / extract time. Integrity is still
#    verified for every codec. Timings are the average of 3 runs and are
#    indicative (single machine, warm cache), not a formal benchmark.
#    codec 比較：打包一張較大、可壓縮的 RGB1 影像（1024×1024 → 3 MiB payload），
#    回報各 swift_tar codec 的封存大小、壓縮比與建立／解出耗時。每個 codec 仍驗證
#    完整性。耗時為 3 次平均、僅供參考（單機、熱快取），非正式基準。
# ---------------------------------------------------------------------------
now() { perl -MTime::HiRes=time -e 'printf "%.6f", time'; }
ms()  { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", (b-a)*1000}'; }

# The codec table is also written to verifications/ as a committed .txt, the
# same convention as the other measurement scripts (*_output.txt); the full
# PASS/FAIL log stays in test_swift_tar_rgb1.log (ignored by *.log).
# codec 比較表另存一份到 verifications/ 的 .txt（會入版），與其他量測腳本
# （*_output.txt）慣例相同；完整 PASS/FAIL log 留在 test_swift_tar_rgb1.log
# （被 *.log 忽略）。
#
# Suffixed by platform. A single shared file made this a trap: the committed
# table was recorded on Windows, and one run of this script on macOS silently
# replaced it with macOS numbers — the loss showing up only as an unexplained
# diff. Each platform now owns its own file and they can all be committed.
# 依平台加後綴。共用單一檔案會造成陷阱：入版的表格錄自 Windows，而本腳本在 macOS
# 上跑一次就會靜默地把它換成 macOS 的數字——只留下一個沒人解釋得清的 diff。現在每個
# 平台各自擁有一個檔案，三者可同時入版。
. "$HERE/platform.sh"
RESULTS="$HERE/verifications/rgb1_container_mbps_output-$(swift_tar_platform).txt"
: > "$RESULTS"
emit() { echo "$1"; echo "$1" >> "$RESULTS"; }

# A real sampled video frame, not a synthetic pattern. This used to be a 4 KiB
# random block repeated 768 times, which is perfectly periodic: every codec with
# a window of 4 KiB or more finds an exact match at once and the table reported
# zstd at a ratio of 0.001 -- a thousandth of raw, where a real 1080p frame
# compresses to about half. The numbers were not wrong for what they measured;
# they were measuring a pattern, not an image, while the row was labelled
# "RGB1 container". The block was also re-randomised every run, so the record
# could not be compared across runs or platforms: the mac/win difference of
# 7 bytes once read as a library difference was only a different corpus.
# 使用真實取樣的視訊影格，而非合成圖案。此處原本是把 4 KiB 隨機區塊重複 768 次，其週期
# 完全規律：任何視窗達 4 KiB 以上的 codec 都會立刻找到完全匹配，於是表格把 zstd 記為
# 壓縮比 0.001——原始大小的千分之一，而真實 1080p 影格約為一半。那些數字就其所量測的
# 對象而言並沒有錯，錯在它量的是「圖案」而非「影像」，該列卻標示為「RGB1 container」。
# 該區塊每次執行還會重新隨機，故紀錄無法跨執行或跨平台比較：先前 mac 與 win 相差 7
# 位元組一度被讀成函式庫差異，其實只是語料不同。
#
# No synthetic fallback. A record from the wrong corpus is worse than no record,
# and the corpus is one command away (make_consecutive_corpus.zsh).
# 不提供合成備援。來自錯誤語料的紀錄比沒有紀錄更糟，而該語料只差一道指令即可產生
# （make_consecutive_corpus.zsh）。
BIGSRC=""
for d in "$HERE/verifications/rgb1/sample_consecutive" "$HERE/verifications/rgb1/sample"; do
  for f in "$d"/*.rgb1; do
    [ -f "$f" ] || continue
    BIGSRC="$TMP/bigsrc"; mkdir -p "$BIGSRC"
    cp "$f" "$BIGSRC/big.rgb1"
    CORPUS_FRAME="${f#$HERE/}"
    break 2
  done
done
if [ -z "$BIGSRC" ]; then
  echo "SKIP: codec table needs a sampled frame; run verifications/rgb1/make_consecutive_corpus.zsh"
  echo "SKIP：codec 比較表需要取樣影格，請先執行 verifications/rgb1/make_consecutive_corpus.zsh"
  echo
  echo "PASS: $pass  FAIL: $fail"
  [ "$fail" -eq 0 ]
  exit $?
fi
BIG_BYTES="$(wc -c < "$BIGSRC/big.rgb1" | tr -d ' ')"
BIG_PAYLOAD="$("$ST" --rgb1-info -f "$BIGSRC/big.rgb1" | grep '^payload_bytes=' | cut -d= -f2)"

bench_base=""   # plain-tar size, used as the ratio baseline / 純 tar 大小，作為比率基準
# Throughput is the RGB1 container size handled per second (MB = 10^6 bytes):
# create reads the .rgb1 and writes the archive; extract writes the .rgb1 back.
# 吞吐量為每秒處理的 RGB1 容器大小（MB = 10^6 bytes）：建立時讀 .rgb1 寫封存，
# 解出時寫回 .rgb1。
mbps() { awk -v bytes="$1" -v t="$2" 'BEGIN{ if (t>0) printf "%.1f", bytes/(1000.0*t); else printf "n/a"; }'; }
# The OS build, not just the product version, identifies the environment:
# macOS 27.0 build 26A5388g reported CPU Power 0 mW where 26A5406e did not.
# 辨識環境要看 OS build 而非僅產品版本：macOS 27.0 的 26A5388g 回報
# CPU Power 0 mW，26A5406e 則否。
emit "[Info] date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
emit "[Info] os: $(command -v sw_vers >/dev/null 2>&1 && echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))" || uname -sr)"
emit "[Info] host: $(uname -srm)"
emit "[Info] swift_tar: $ST"
emit "[Info] version: $("$ST" --version 2>/dev/null | head -1)"
emit "[Info] corpus: sampled video frame $CORPUS_FRAME ($BIG_BYTES B incl. 876 B header)"
emit "[Info] MB/s = container bytes / time (MB = 10^6); times are the mean of 3 runs"
emit ""
emit "== RGB1 container: size / time / throughput by codec =="
emit "$(printf '%-16s %12s %7s %11s %9s %11s %9s' "codec" "size(B)" "ratio" "create(ms)" "cr(MB/s)" "extract(ms)" "ex(MB/s)")"
emit "$(printf '%-16s %12s %7s %11s %9s %11s %9s' "----------------" "------------" "-------" "-----------" "---------" "-----------" "---------")"
bench() { # label codec-flags archive-name
  # $2 is split into words, so a codec can carry its own options. It used to be
  # a single quoted argument, which meant a level could not be pinned and every
  # zstd row silently followed swift_tar's default -- that default moved from 3
  # to 9 on 2026-08-14 and would have re-based this table without saying so.
  # $2 會被拆成多個詞，使 codec 得以夾帶自身選項。原本它是單一引號參數，導致無法釘住
  # 等級，每一列 zstd 都靜默沿用 swift_tar 的預設值——而該預設已於 2026-08-14 由 3 改為
  # 9，會在不聲明的情況下改變本表的基準。
  local label="$1" arc="$TMP/$3" out="$TMP/xb_$3"
  local -a flag; read -r -a flag <<< "$2"
  # create: skip this codec if unsupported (e.g. missing CLI) / 建立：不支援則略過
  if [ ${#flag[@]} -gt 0 ]; then
    if ! "$ST" -c "${flag[@]}" -f "$arc" -C "$BIGSRC" big.rgb1 >/dev/null 2>&1; then
      emit "$(printf '%-16s %12s' "$label" "SKIP(unsupported)")"; return
    fi
  else
    "$ST" -c -f "$arc" -C "$BIGSRC" big.rgb1
  fi
  # average create time over 3 runs / 建立耗時取 3 次平均
  local i s e sum=0
  for i in 1 2 3; do
    s=$(now); { [ ${#flag[@]} -gt 0 ] && "$ST" -c "${flag[@]}" -f "$arc" -C "$BIGSRC" big.rgb1 >/dev/null 2>&1 || "$ST" -c -f "$arc" -C "$BIGSRC" big.rgb1; } ; e=$(now)
    sum=$(awk -v s="$sum" -v d="$(ms "$s" "$e")" 'BEGIN{print s+d}')
  done
  local ctime; ctime=$(awk -v s="$sum" 'BEGIN{printf "%.1f", s/3}')
  local size; size=$(wc -c < "$arc" | tr -d ' ')
  [ -z "$bench_base" ] && bench_base="$size"
  local ratio; ratio=$(awk -v x="$size" -v b="$bench_base" 'BEGIN{printf "%.3f", x/b}')
  # average extract time over 3 runs + integrity on the last one / 解出耗時 3 次平均，末次驗證完整性
  sum=0
  for i in 1 2 3; do
    rm -rf "$out"; mkdir -p "$out"
    s=$(now); "$ST" -x -f "$arc" -C "$out" >/dev/null 2>&1; e=$(now)
    sum=$(awk -v s="$sum" -v d="$(ms "$s" "$e")" 'BEGIN{print s+d}')
  done
  local xtime; xtime=$(awk -v s="$sum" 'BEGIN{printf "%.1f", s/3}')
  local cmbps xmbps
  cmbps=$(mbps "$BIG_BYTES" "$ctime"); xmbps=$(mbps "$BIG_BYTES" "$xtime")
  emit "$(printf '%-16s %12s %7s %11s %9s %11s %9s' "$label" "$size" "$ratio" "$ctime" "$cmbps" "$xtime" "$xmbps")"
  # integrity: extracted big.rgb1 must match the source byte-for-byte and still
  # decode / 完整性：解出的 big.rgb1 須與來源位元組一致且仍可解析
  # The expected payload size comes from the source frame, not a constant. It was
  # hardcoded to 3145728 for the old 1024x1024 synthetic corpus, so switching to a
  # 1920x1080 sampled frame made every codec -- including plain tar, which does
  # not compress at all -- report "round-trip corrupted" while cmp said the bytes
  # were identical. A test that cries corruption at intact data costs as much
  # trust as one that misses real corruption.
  # 期望的 payload 大小取自來源影格，而非常數。它原本為舊的 1024x1024 合成語料寫死為
  # 3145728，故改用 1920x1080 的取樣影格後，每一個 codec——包括完全不壓縮的 plain
  # tar——都回報「round-trip corrupted」，而 cmp 明明判定位元組完全相同。一個對完好
  # 資料喊損毀的測試，損失的信任與漏掉真實損毀一樣多。
  if cmp -s "$BIGSRC/big.rgb1" "$out/big.rgb1" \
     && [ "$("$ST" --rgb1-info -f "$out/big.rgb1" | grep '^payload_bytes=' | cut -d= -f2)" = "$BIG_PAYLOAD" ]; then
    ok "codec $label: sampled .rgb1 round-trip intact"
  else
    bad "codec $label: sampled .rgb1 round-trip corrupted"
  fi
}

bench "plain"  ""        "big.tar"
bench "gzip"   "--gzip"  "big.tar.gz"
bench "bzip2"  "--bzip2" "big.tar.bz2"
bench "xz"     "--xz"    "big.tar.xz"
bench "zstd"   "--zstd --zstd-level 9"  "big.tar.zst"
bench "lz4"    "--lz4"   "big.tar.lz4"
bench "zip"    "--zip"   "big.zip"
# LZFSE-family codecs exist only in the full build. In the --no-lzfse build the
# flags are unknown and silently fall back to plain tar, so probe -h for support
# and skip them rather than reporting a misleading ratio 1.000 row.
# LZFSE 家族 codec 僅存在於全功能版。--no-lzfse 版中這些旗標為未知、會靜默退回
# 純 tar，故先探測 -h 是否支援，不支援就略過，避免印出誤導的 ratio 1.000。
if "$ST" -h 2>&1 | grep -q -- "--bvx3-optimal"; then
  bench "bvx3-optimal"   "--bvx3-optimal"   "big.tar.bvx3"
  bench "other3-optimal" "--other3-optimal" "big.tar.other3"
else
  emit "# LZFSE codecs unavailable in this build (--no-lzfse); skipped / 此建置無 LZFSE codec（--no-lzfse），略過"
fi

# ---------------------------------------------------------------------------
echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
