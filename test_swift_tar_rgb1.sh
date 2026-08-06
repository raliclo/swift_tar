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
RESULTS="$HERE/verifications/rgb1_container_mbps_output.txt"
: > "$RESULTS"
emit() { echo "$1"; echo "$1" >> "$RESULTS"; }

# 3 MiB payload with a 4 KiB redundancy period: compressible, but rewards larger
# windows (zstd/xz) over gzip. Size == 1024*1024*3 exactly. / 3 MiB payload，4 KiB
# 週期冗餘：可壓縮，且大視窗（zstd/xz）優於 gzip。大小恰為 1024*1024*3。
BLOCK="$TMP/block"; head -c 4096 /dev/urandom > "$BLOCK"
BIGRAW="$TMP/big.rgb"; : > "$BIGRAW"
for _ in $(seq 768); do cat "$BLOCK"; done > "$BIGRAW"   # 768*4096 = 3145728 = 1024*1024*3
[ "$(wc -c < "$BIGRAW" | tr -d ' ')" -eq 3145728 ] || { echo "internal: BIGRAW size wrong"; exit 2; }

BIGSRC="$TMP/bigsrc"; mkdir -p "$BIGSRC"
"$ST" --rgb1-pack --width 1024 --height 1024 --lat 25 --lng 121 --height-m 1 \
      --title big --country TW --creator-email a@b.co --right R \
      --created-ms 1700000000000 -f "$BIGSRC/big.rgb1" "$BIGRAW"
BIG_BYTES="$(wc -c < "$BIGSRC/big.rgb1" | tr -d ' ')"   # 3145728 + 876 header

bench_base=""   # plain-tar size, used as the ratio baseline / 純 tar 大小，作為比率基準
# Throughput is the RGB1 container size handled per second (MB = 10^6 bytes):
# create reads the .rgb1 and writes the archive; extract writes the .rgb1 back.
# 吞吐量為每秒處理的 RGB1 容器大小（MB = 10^6 bytes）：建立時讀 .rgb1 寫封存，
# 解出時寫回 .rgb1。
mbps() { awk -v bytes="$1" -v t="$2" 'BEGIN{ if (t>0) printf "%.1f", bytes/(1000.0*t); else printf "n/a"; }'; }
emit "[Info] date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
emit "[Info] host: $(uname -srm)"
emit "[Info] swift_tar: $ST"
emit "[Info] version: $("$ST" --version 2>/dev/null | head -1)"
emit "[Info] corpus: synthetic RGB1 1024x1024 (3 MiB payload + 876B header = $BIG_BYTES B)"
emit "[Info] MB/s = container bytes / time (MB = 10^6); times are the mean of 3 runs"
emit ""
emit "== RGB1 container: size / time / throughput by codec =="
emit "$(printf '%-16s %12s %7s %11s %9s %11s %9s' "codec" "size(B)" "ratio" "create(ms)" "cr(MB/s)" "extract(ms)" "ex(MB/s)")"
emit "$(printf '%-16s %12s %7s %11s %9s %11s %9s' "----------------" "------------" "-------" "-----------" "---------" "-----------" "---------")"
bench() { # label codec-flag archive-name
  local label="$1" flag="$2" arc="$TMP/$3" out="$TMP/xb_$3"
  # create: skip this codec if unsupported (e.g. missing CLI) / 建立：不支援則略過
  if [ -n "$flag" ]; then
    if ! "$ST" -c "$flag" -f "$arc" -C "$BIGSRC" big.rgb1 >/dev/null 2>&1; then
      emit "$(printf '%-16s %12s' "$label" "SKIP(unsupported)")"; return
    fi
  else
    "$ST" -c -f "$arc" -C "$BIGSRC" big.rgb1
  fi
  # average create time over 3 runs / 建立耗時取 3 次平均
  local i s e sum=0
  for i in 1 2 3; do
    s=$(now); { [ -n "$flag" ] && "$ST" -c "$flag" -f "$arc" -C "$BIGSRC" big.rgb1 >/dev/null 2>&1 || "$ST" -c -f "$arc" -C "$BIGSRC" big.rgb1; } ; e=$(now)
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
  if cmp -s "$BIGSRC/big.rgb1" "$out/big.rgb1" \
     && [ "$("$ST" --rgb1-info -f "$out/big.rgb1" | grep '^payload_bytes=' | cut -d= -f2)" = "3145728" ]; then
    ok "codec $label: 3 MiB .rgb1 round-trip intact"
  else
    bad "codec $label: 3 MiB .rgb1 round-trip corrupted"
  fi
}

bench "plain"  ""        "big.tar"
bench "gzip"   "--gzip"  "big.tar.gz"
bench "bzip2"  "--bzip2" "big.tar.bz2"
bench "xz"     "--xz"    "big.tar.xz"
bench "zstd"   "--zstd"  "big.tar.zst"
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
