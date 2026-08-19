#!/usr/bin/env zsh
# test_swift_tar_rgb1.zsh
# Integration test: an RGB1 container packed by swift_tar must survive a full
# archive round-trip through swift_tar's own tar / gzip / zip pipelines and come
# back byte-for-byte, with --rgb1-info and --rgb1-raw still decoding correctly.
# Also checks interop: the platform's standard tar extracts swift_tar's plain
# tar of the .rgb1 without corrupting it. This complements test_rgb1.zsh (which
# unit-tests the three RGB1 modes in isolation).
# 整合測試：swift_tar 打包出的 RGB1 容器，經 swift_tar 自身的 tar / gzip / zip
# 封存往返後，必須位元組級一致，且 --rgb1-info 與 --rgb1-raw 仍能正確解析。
# 另驗證互通：系統標準 tar 能解出 swift_tar 的純 tar .rgb1 而不損壞。此測試補足
# test_rgb1.zsh（後者單獨測 RGB1 三個模式）。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${ST:-}" ]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$HERE/release/swift_tar.exe" ;;
    *) ST="$HERE/release/swift_tar" ;;
  esac
fi
SYS_TAR="$(command -v tar)"

# --record is opt-in because this is a correctness test that happens to also
# measure. Every run used to overwrite the committed table, so any run rewrote
# the record whether or not anyone meant to publish it -- including runs under
# machine load, which is how a table arrived once with every time uniformly ~8%
# slower and sizes unchanged. A record that changes as a side effect of testing
# cannot be compared across runs, because nobody chose when it was taken.
# --record 採取選擇性加入，因為這是一支恰好也做量測的正確性測試。先前每次執行都會覆寫
# 入版的表格，於是任何一次執行都在改寫紀錄，無論是否有意發佈——包括在機器負載下的執行，
# 那正是某次表格所有時間一致慢約 8%、體積卻幾乎不變的由來。一份因測試副作用而變動的
# 紀錄無法跨執行比較，因為沒有人決定過它是何時取得的。
RECORD=0
for arg in "$@"; do
  case "$arg" in
    --record) RECORD=1 ;;
    *) echo "usage: $0 [--record]   # --record 才寫入 verifications/ 的量測紀錄" >&2; exit 2 ;;
  esac
done

if [ ! -x "$ST" ]; then
  echo "error: build first (./compile_tar.zsh) — missing $ST" >&2
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
. "$HERE/platform.zsh"
RESULTS="$HERE/verifications/rgb1_container_mbps_output-$(swift_tar_platform).txt"

# Built in a temp file and moved into place only after the last codec passes,
# rather than truncating the committed file up front and appending as we go.
# Truncating first means a failure anywhere in the table -- a codec that errors,
# a corpus that is missing, an interrupt -- leaves a half-written record in the
# tree that still looks like a record.
# 先寫入暫存檔，待最後一個 codec 通過後才搬移到位，而非一開始就截斷入版檔案再逐行附加。
# 先截斷的話，表格中任何一處失敗——某個 codec 出錯、語料缺失、執行被中斷——都會在程式庫
# 裡留下一份寫到一半、外觀卻仍像一份完整紀錄的檔案。
# Staged inside $TMP so the existing `trap cleanup EXIT` removes it. A second
# `trap ... EXIT` would not run alongside the first, it would replace it, and
# the work directory would be left in the tree after every run.
# 暫存於 $TMP 之內，交由既有的 `trap cleanup EXIT` 清除。再設一個 `trap ... EXIT`
# 並不會與前一個並存，而是取代它，導致每次執行後工作目錄都留在程式庫中。
STAGE="$TMP/rgb1_mbps.txt"
emit() { echo "$1"; echo "$1" >> "$STAGE"; }
if [ "$RECORD" = 1 ]; then
  echo "[Info] --record given; will update $RESULTS on success / 指定 --record，成功後將更新該檔"
else
  echo "[Info] measuring only; $(basename "$RESULTS") not touched (pass --record to update)"
  echo "[Info] 僅量測，不寫入 $(basename "$RESULTS")（要更新請加 --record）"
fi

# ---------------------------------------------------------------------------
# A rejected text field must say which rule it broke.
# Four separate causes -- non-ASCII, empty, over the byte limit, and a control
# character -- used to produce byte-identical messages ("RGB1 text field is
# invalid: title"), so the only way to learn which rule applied was to re-read
# the flag table. The curly-quote case matters most in practice: a title pasted
# from a word processor looks like ASCII on screen. Each check asserts a
# distinct substring, so two causes collapsing back into one message fails here
# rather than passing quietly.
#
# Placed ABOVE the codec-table section on purpose: that section exits the script
# outright when no sampled frame corpus is present, which is the common case on
# a fresh checkout. Put below it, these checks printed nothing and the suite
# still reported success -- the same shape as a test skipped by a platform
# guard, and just as invisible.
#
# 遭拒的文字欄位必須說出它違反了哪一條規則。
# 四種各自獨立的成因——非 ASCII、空白、超出位元組上限、控制字元——原本產生逐位元組
# 相同的訊息（「RGB1 text field is invalid: title」），因此要知道適用哪條規則，只能
# 回頭重讀旗標表。實務上最要緊的是彎引號：從文書軟體貼上的標題，在畫面上看起來就是
# ASCII。每項檢查斷言一個相異的子字串，故兩種成因若又併回同一則訊息，會在此失敗而非
# 悄悄通過。
#
# 刻意置於 codec 比較表一節**之前**：該節在沒有取樣影格語料時會直接結束整個腳本，而
# 那正是全新取出的儲存庫上的常態。放在其後時，這些檢查什麼都不會印，而測試套件仍回報
# 成功——與被平台守衛跳過的測試是同一個形狀，也同樣看不見。
# ---------------------------------------------------------------------------
pack_err() {
  "$ST" --rgb1-pack --width 4 --height 3 \
        --lat 25.0 --lng 121.0 --height-m 12.0 \
        --title "$1" --country "${2:-Taiwan}" \
        --creator-email "${3:-photog@example.com}" --right "${4:-CcBy}" \
        --created-ms 1700000000123 \
        -f "$TMP/reject.rgb1" "$RAW" 2>&1
}

check_reason() {   # label, expected substring, actual message
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 (got: $(printf '%s' "$3" | head -1 | cut -c1-90))" ;;
  esac
}

check_reason "a non-ASCII title says it must be ASCII" \
  "must be ASCII" "$(pack_err '台北資料')"
check_reason "a curly quote is reported the same way as any other non-ASCII" \
  "must be ASCII" "$(pack_err 'the “title”')"
check_reason "an over-long title reports the limit and the actual size" \
  "at most 64 bytes, and this is 70" "$(pack_err "$(printf 'x%.0s' {1..70})")"
check_reason "an empty title says it must not be empty" \
  "must not be empty" "$(pack_err '')"
check_reason "a malformed email says what an address looks like" \
  "one '@' with text on both sides" "$(pack_err 'Fine' 'Taiwan' 'not-an-email')"
check_reason "a bad --right says what it accepts" \
  "ASCII letters" "$(pack_err 'Fine' 'Taiwan' 'photog@example.com' 'CcBy1')"
# A second field, to prove the message names the field that actually failed
# rather than always saying "title". Non-ASCII rather than empty: `${2:-Taiwan}`
# above substitutes the default for an empty argument as well as a missing one,
# so passing '' would have tested nothing and did -- it packed successfully and
# this check failed against a correct build.
# 換一個欄位，以證明訊息指出的是真正失敗的那個欄位，而非一律說 "title"。用非 ASCII
# 而不用空字串：上方的 `${2:-Taiwan}` 對空引數與缺少引數同樣會代入預設值，因此傳 ''
# 什麼也沒測到——實際上它成功打包了，並使此檢查在一份正確的建置上失敗。
check_reason "the message names the field that failed, not always 'title'" \
  "'country'" "$(pack_err 'Fine' '台灣')"

# A bad -f must say what is wrong with it. Foundation's own descriptions here do
# not merely fail to help, they misdirect: writing onto an existing directory
# reported "You don't have permission", sending the reader to check ownership or
# re-run elevated when the only problem is that -f names a directory; a missing
# parent reported "The file doesn't exist", naming no file and pointing at the
# output rather than the directory above it. Nothing is destroyed either way --
# the behaviour was always safe, only the wording was wrong.
# 錯誤的 -f 必須說出它哪裡不對。Foundation 自帶的描述在此不只是幫不上忙，而是誤導：
# 寫到既有目錄上會回報「您沒有權限」，使讀者跑去查擁有者或改用系統管理員身分重跑，
# 而唯一的問題只是 -f 指向了目錄；父目錄不存在則回報「檔案不存在」，既沒點名任何檔案，
# 指的方向也是輸出本身而非其上層目錄。兩種情形都不會破壞任何東西——行為一向安全，
# 錯的只有措辭。
mkdir -p "$TMP/rgb_outdir"
out_err() {
  "$ST" --rgb1-pack --width 4 --height 3 \
        --lat 25.0 --lng 121.0 --height-m 12.0 \
        --title Fine --country Taiwan --creator-email photog@example.com --right CcBy \
        --created-ms 1700000000123 -f "$1" "$RAW" 2>&1
}
check_reason "-f at an existing directory says it is a directory" \
  "is a directory, not a file to write" "$(out_err "$TMP/rgb_outdir")"
check_reason "-f under a missing directory names that directory" \
  "does not exist" "$(out_err "$TMP/rgb_nodir/out.rgb1")"
[ -d "$TMP/rgb_outdir" ] && ok "the existing directory is left alone" \
                         || bad "the existing directory is left alone"

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
  # (N) null-glob: neither sample dir is required to exist, and zsh's default
  # NOMATCH would abort here rather than fall through to the no-corpus path.
  # (N) null-glob：兩個 sample 目錄都非必要存在，而 zsh 預設的 NOMATCH 會在此
  # 中止，走不到「無語料」的路徑。
  for f in "$d"/*.rgb1(N); do
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
  # ${=2} forces word-splitting, which zsh does not do by default; this is the
  # zsh equivalent of bash's `read -r -a flag <<< "$2"` (zsh's read has no -a).
  # ${=2} 強制分詞——zsh 預設不對變數分詞；此為 bash `read -r -a` 的 zsh 等價寫法
  # （zsh 的 read 沒有 -a 選項）。
  local -a flag; flag=(${=2})
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
# flags are rejected outright (exit 1), which under `set -e` would abort this
# script, so probe -h for support and skip them instead.
# They used to be accepted and ignored, producing a misleading ratio 1.000 row;
# the probe was added for that and is still required, now for the opposite
# reason -- the failure it avoids became loud rather than silent.
# LZFSE 家族 codec 僅存在於全功能版。--no-lzfse 版會直接拒絕這些旗標（exit 1），在
# `set -e` 下會中止本腳本，故先探測 -h 是否支援，不支援就略過。
# 這些旗標從前是被接受後忽略，會產生誤導的 ratio 1.000 那一列；此探測原為該情況而加，
# 現在仍然必要，但理由相反——它所迴避的失敗已從靜默變為顯性。
if "$ST" -h 2>&1 | grep -q -- "--bvx3-optimal"; then
  bench "bvx3-optimal"   "--bvx3-optimal"   "big.tar.bvx3"
  bench "other3-optimal" "--other3-optimal" "big.tar.other3"
else
  emit "# LZFSE codecs unavailable in this build (--no-lzfse); skipped / 此建置無 LZFSE codec（--no-lzfse），略過"
fi

# ---------------------------------------------------------------------------
# A rejected text field must say which rule it broke.
# Four separate causes -- non-ASCII, empty, over the byte limit, and a control
# character -- used to produce byte-identical messages ("RGB1 text field is
# invalid: title"), so the only way to learn which rule applied was to re-read
# the flag table. The curly-quote case is the one that matters most in practice:
# a title pasted from a word processor looks like ASCII on screen.
# Each check asserts a distinct substring, so two causes collapsing back into
# one message fails here rather than passing quietly.
#
# 遭拒的文字欄位必須說出它違反了哪一條規則。
# 四種各自獨立的成因——非 ASCII、空白、超出位元組上限、控制字元——原本產生逐位元組
# 相同的訊息（「RGB1 text field is invalid: title」），因此要知道適用哪條規則，只能
# 回頭重讀旗標表。實務上最要緊的是彎引號那個案例：從文書軟體貼上的標題，在畫面上看
# 起來就是 ASCII。每項檢查斷言一個相異的子字串，故兩種成因若又併回同一則訊息，會在
# 此失敗而非悄悄通過。
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Only a fully passing run may publish. A table produced by a run that also
# reported failures is a measurement of a build known to be wrong.
# 唯有全數通過的執行才可發佈。一次同時回報失敗的執行所產出的表格，量測的是一份已知有誤
# 的建置。
if [ "$RECORD" = 1 ]; then
  if [ "$fail" -eq 0 ]; then
    cp "$STAGE" "$RESULTS"
    echo "[Info] recorded → $RESULTS / 已寫入紀錄"
  else
    echo "[Warn] $fail failure(s); $RESULTS left unchanged / 有失敗，紀錄未更動" >&2
  fi
fi

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
