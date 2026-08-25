#!/usr/bin/env zsh
# test_blind_findings.zsh -- regression tests for the defects found by the
# read_easy blind documentation test (rounds 1-16, 2026-08-18).
# test_blind_findings.zsh -- read_easy 盲測（2026-08-18，round 1-16）所發現
# 缺陷的回歸測試。
#
#   ./test/test_blind_findings.zsh          # run against release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_blind_findings.zsh   # or a specific binary
#   ./test/test_blind_findings.zsh --help
#
# Each case below reproduced a real defect before its fix. Two of them are the
# reason this file uses `timeout` at all: a hang is the failure mode, and a test
# that hangs alongside the program it is testing reports nothing.
# 以下每個案例在修復前都能重現真實缺陷。其中兩項正是本檔必須使用 `timeout` 的
# 原因：失敗形態就是卡死，而與受測程式一起卡死的測試什麼也回報不了。
set -euo pipefail

script_path="${0:A}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,14p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

HERE="${script_path:h}"
ROOT="${HERE:h}"
if [ -z "${ST:-}" ]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$ROOT/release/swift_tar.exe" ;;
    *) ST="$ROOT/release/swift_tar" ;;
  esac
fi
if [ ! -x "$ST" ]; then
  echo "error: build first — missing swift_tar release binary" >&2
  exit 1
fi

SYS_TAR="${SYS_TAR:-tar}"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0
fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
eq() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then ok "$desc"; else bad "$desc (want '$want', got '$got')"; fi
}

SRC="$TMP/src"
mkdir -p "$SRC/tree/sub"
printf 'alpha\n' > "$SRC/tree/a.txt"
printf 'bravo\n' > "$SRC/tree/sub/b.txt"
# zstd needs enough redundancy for the level to change the output size.
# zstd 需要足夠的重複性，壓縮等級才會改變輸出大小。
for i in $(seq 1 400); do printf 'the quick brown fox jumps over the lazy dog %s\n' "$i"; done > "$SRC/tree/bulk.txt"

# ---- round 1 / 8: a trailing slash must not double the separator ----
# A trailing slash is what shell tab-completion produces, so this is the common
# spelling, not an exotic one. Unfixed it doubled every stored name, which broke
# name matching rather than merely looking wrong.
# 尾隨斜線正是 shell tab 補全產生的形式，故屬常見寫法而非罕例。未修復時它會使
# 每個檔內名稱加倍，破壞的是名稱比對，而不只是看起來怪。
( cd "$SRC" && "$ST" -c -f "$TMP/slash.tar" tree/ )
( cd "$SRC" && "$SYS_TAR" -cf "$TMP/ref.tar" tree/ )
mine="$("$ST" -t -f "$TMP/slash.tar" | sort | tr '\n' ' ')"
theirs="$("$SYS_TAR" -tf "$TMP/ref.tar" | sort | tr '\n' ' ')"
eq "trailing slash: entry names match system tar" "$theirs" "$mine"

case "$mine" in
  *//*) bad "trailing slash: no doubled separator in stored names" ;;
  *) ok "trailing slash: no doubled separator in stored names" ;;
esac

# --delete must match the name the user types, which is the name on disk --
# not the doubled spelling that only appears in -t output.
# --delete 必須比對使用者鍵入的名稱（即磁碟上的名稱），而非只出現在 -t 輸出中
# 的加倍寫法。
n_before="$("$ST" -t -f "$TMP/slash.tar" | wc -l | tr -d ' ')"
if "$ST" --delete -f "$TMP/slash.tar" tree/a.txt >/dev/null 2>&1; then
  eq "--delete matches a name spelled as on disk" "$((n_before - 1))" \
     "$("$ST" -t -f "$TMP/slash.tar" | wc -l | tr -d ' ')"
else
  bad "--delete matches a name spelled as on disk"
fi

# The listing must be LF, like system tar's. Windows opens the CRT stdout in
# text mode, so print() used to emit CRLF and every line of a diff against a
# bsdtar listing differed by one invisible byte. Counted with tr, never grep:
# MSYS tools read in text mode and strip CR before the regex ever runs.
# 列表必須與系統 tar 一樣是 LF。Windows 的 CRT stdout 預設文字模式，故 print()
# 曾送出 CRLF，使得與 bsdtar 列表做 diff 時每一行都差一個看不見的位元組。以 tr
# 計數而非 grep：MSYS 工具以文字模式讀檔，在正則執行前就已剝除 CR。
eq "-t listing has no CR bytes" "0" "$("$ST" -t -f "$TMP/slash.tar" | tr -dc '\r' | wc -c | tr -d ' ')"
eq "--identify has no CR bytes" "0" "$("$ST" --identify -f "$TMP/slash.tar" | tr -dc '\r' | wc -c | tr -d ' ')"

# -u across two spellings of the same tree must not re-append every member.
# Unfixed, 4 entries became 8 with nothing modified: every member was judged
# absent because the stored name did not match.
# 以兩種拼法對同一棵樹做 -u，不可重新追加所有成員。未修復時在零修改的情況下
# 4 筆會變成 8 筆：所有成員都因檔內名稱不符而被判為不存在。
( cd "$SRC" && "$ST" -c -f "$TMP/upd.tar" tree/ )
before="$("$ST" -t -f "$TMP/upd.tar" | wc -l | tr -d ' ')"
( cd "$SRC" && "$ST" -u -f "$TMP/upd.tar" tree )
after="$("$ST" -t -f "$TMP/upd.tar" | sort -u | wc -l | tr -d ' ')"
eq "-u across spellings does not duplicate members" "$before" "$after"

# ---- round 4: non-terminal stdin must refuse, not block ----
# Both shapes matter and they used to differ: a pipe was caught, `< /dev/null`
# was not, because Windows _isatty() is true for the NUL character device.
# The timeout is the assertion -- without it a regression hangs the suite.
# 兩種形態都重要且曾有差異：管線擋得住，`< /dev/null` 擋不住，因為 Windows 的
# _isatty() 對 NUL 字元裝置為真。timeout 本身就是斷言——沒有它，一旦退化整個
# 測試套件會直接卡死。
rc=0; timeout 20 "$ST" -c --encrypt -f "$TMP/np.enc" -C "$SRC" tree < /dev/null >/dev/null 2>&1 || rc=$?
eq "--encrypt refuses stdin from /dev/null (no hang)" "1" "$rc"
[ ! -e "$TMP/np.enc" ] && ok "--encrypt writes no archive when it refuses" \
  || bad "--encrypt writes no archive when it refuses"

rc=0; printf '' | timeout 20 "$ST" -c --encrypt -f "$TMP/pp.enc" -C "$SRC" tree >/dev/null 2>&1 || rc=$?
eq "--encrypt refuses stdin from a pipe (no hang)" "1" "$rc"

# ---- round: inline --opt=value must be read, not ignored ----
# Validation accepts `--flag=value` by comparing only the name before "=", so
# every value reader has to understand it. When they did not, --keyfile=PATH
# fell through to the interactive prompt and hung with no archive.
# 驗證層只比對 "=" 之前的名稱因而接受 `--flag=value`，故每個讀值端都必須認得它。
# 當它們不認得時，--keyfile=PATH 會落到互動式提示並卡死，且毫無產出。
head -c 64 /dev/urandom > "$TMP/k.bin"
rc=0; timeout 20 "$ST" -c --encrypt --keyfile="$TMP/k.bin" -f "$TMP/inline.enc" -C "$SRC" tree >/dev/null 2>&1 || rc=$?
eq "--keyfile=PATH is honoured (no prompt, no hang)" "0" "$rc"

mkdir -p "$TMP/out"
if timeout 20 "$ST" -x --keyfile="$TMP/k.bin" -f "$TMP/inline.enc" -C "$TMP/out" >/dev/null 2>&1 \
   && diff -r "$SRC/tree" "$TMP/out/tree" >/dev/null 2>&1; then
  ok "--keyfile=PATH round-trips"
else
  bad "--keyfile=PATH round-trips"
fi

# --zstd-level=N was the silent one: the archive came out byte-identical to the
# default while the command exited 0, so a benchmark recorded the wrong level.
# --zstd-level=N 是靜默的那個：產出的封存與預設完全相同，指令卻以 0 結束，於是
# benchmark 記下的是另一個等級的數字。
"$ST" -c --zstd --zstd-level 19 -f "$TMP/space.tzst" -C "$SRC" tree
"$ST" -c --zstd --zstd-level=19 -f "$TMP/inline.tzst" -C "$SRC" tree
"$ST" -c --zstd            -f "$TMP/default.tzst" -C "$SRC" tree
cmp -s "$TMP/space.tzst" "$TMP/inline.tzst" \
  && ok "--zstd-level=N matches --zstd-level N" \
  || bad "--zstd-level=N matches --zstd-level N"
cmp -s "$TMP/inline.tzst" "$TMP/default.tzst" \
  && bad "--zstd-level=N is not silently ignored" \
  || ok "--zstd-level=N is not silently ignored"

# ---- round 6: one failure status, not two ----
# --zstd-level held the only exit(2) in the program against sixteen exit(1),
# so a caller branching on the value got an answer no other error path gives.
# --zstd-level 曾是全程式唯一的 exit(2)，對比十六處 exit(1)；依離開碼分支的
# 呼叫端會得到其他錯誤路徑都不會給的答案。
rc=0; "$ST" -c --zstd --zstd-level 99 -f "$TMP/bad.tzst" -C "$SRC" tree >/dev/null 2>&1 || rc=$?
eq "--zstd-level out of range exits 1" "1" "$rc"
rc=0; "$ST" -c --zstd --zstd-level=99 -f "$TMP/bad.tzst" -C "$SRC" tree >/dev/null 2>&1 || rc=$?
eq "--zstd-level=N out of range exits 1" "1" "$rc"

# ---- round 19: extraction must survive a path past Windows MAX_PATH ----
# swift_tar could write archives it could not extract: the pax long-name
# encoding on create is fine and GNU tar reads it, but extraction created
# directories through Foundation, which fails past MAX_PATH -- and the failure
# was discarded by `try?`, so the first symptom was errno 2 on the *file*.
# The bug was deterministic but NOT monotonic in path length: 36 of 97 target
# lengths failed, in bands 12 wide repeating every 31 characters -- one path
# segment. A single length proves nothing, which is why this sweeps.
# swift_tar 曾能寫出自己解不開的封存：建立端的 pax 長檔名編碼正確，GNU tar 也讀得
# 到，但解壓端透過 Foundation 建目錄，而它在超過 MAX_PATH 後即失敗——且該失敗被
# `try?` 丟棄，故最先出現的症狀是**檔案**的 errno 2。此缺陷雖為決定性，卻不隨路徑
# 長度單調變化：97 個目標長度中有 36 個失敗，呈寬 12、每 31 字元重複一次的帶狀
# ——恰為一個路徑分段。單一長度證明不了任何事，故此處採掃描。
DEEP="$TMP/deep/longpath"
mkdir -p "$DEEP"
d="$DEEP"
for i in $(seq 1 10); do d="$d/segment_of_thirty_chars_long_$i"; done
mkdir -p "$d"
printf 'deep\n' > "$d/file_with_a_reasonably_long_name_too.txt"
( cd "$TMP/deep" && "$ST" -c -f "$TMP/deep.tar" longpath )

lp_fail=0
for pad in 8 12 17 23 43 50 74 80 85 96; do
  target="$TMP/$(printf 't%.0s' $(seq 1 $pad))"
  rm -rf "$target"; mkdir -p "$target"
  "$ST" -x -f "$TMP/deep.tar" -C "$target" >/dev/null 2>&1 || lp_fail=$((lp_fail + 1))
  rm -rf "$target"
done
eq "long paths extract at every target length" "0" "$lp_fail"

# And the extracted tree must match what system tar makes of the same archive.
# 且解出的樹必須與系統 tar 對同一封存的結果一致。
rm -rf "$TMP/lpm" "$TMP/lpg"; mkdir -p "$TMP/lpm" "$TMP/lpg"
"$ST" -x -f "$TMP/deep.tar" -C "$TMP/lpm" >/dev/null 2>&1 || true
"$SYS_TAR" -xf "$TMP/deep.tar" -C "$TMP/lpg" >/dev/null 2>&1 || true
eq "long-path tree matches system tar" \
   "$(find "$TMP/lpg" -type d | wc -l | tr -d ' ')" \
   "$(find "$TMP/lpm" -type d | wc -l | tr -d ' ')"

# ---- round 22: the ZIP backend must accept the names tar already accepts ----
# A Traditional Chinese filename round-trips through tar and every stream codec,
# but --zip failed the whole write with "Can't translate pathname to current
# locale" and left a partial .zip behind. libarchive was translating names into
# the process locale; bsdtar avoids this by calling setlocale() at startup,
# which a library must not do, so the backend now names the charset instead.
# 繁體中文檔名在 tar 與各串流 codec 中都能正常往返，--zip 卻會讓整個寫入失敗於
# "Can't translate pathname to current locale" 並留下半個 .zip。原因是 libarchive
# 正把名稱轉換為行程 locale；bsdtar 靠啟動時呼叫 setlocale() 迴避，而函式庫不應
# 這麼做，故本後端改為明確指定字元集。
UNI="$TMP/uni"
mkdir -p "$UNI"
printf 'unicode\n' > "$UNI/繁體.txt"
rc=0; "$ST" -c --zip -f "$TMP/uni.zip" -C "$TMP" uni >/dev/null 2>&1 || rc=$?
eq "--zip accepts a non-ASCII filename" "0" "$rc"

rm -rf "$TMP/uzx"; mkdir -p "$TMP/uzx"
if "$ST" -x -f "$TMP/uni.zip" -C "$TMP/uzx" >/dev/null 2>&1 \
   && diff -r "$UNI" "$TMP/uzx/uni" >/dev/null 2>&1; then
  ok "--zip round-trips a non-ASCII filename"
else
  bad "--zip round-trips a non-ASCII filename"
fi

# -C's documented auto-create must hold for ZIP too, not only for tar. The two
# backends reach the destination differently -- tar joins -C into each entry
# path, ZIP hands it to libarchive to chdir() into -- and only tar created it.
# `-C` 記載的自動建立行為必須同樣適用於 ZIP，而不只是 tar。兩個後端抵達目的地的
# 方式不同——tar 是把 -C 併入每個項目路徑，ZIP 則交給 libarchive 去 chdir()——而
# 過去只有 tar 會建立它。
rm -rf "$TMP/znd"
rc=0; "$ST" -x -f "$TMP/uni.zip" -C "$TMP/znd/a/b" >/dev/null 2>&1 || rc=$?
eq "-x -C creates a missing directory for ZIP too" "0" "$rc"
eq "-x -C ZIP into a missing directory extracts" "1" \
   "$(find "$TMP/znd" -type f 2>/dev/null | wc -l | tr -d ' ')"

# ---- round 23: --zip must never accept an encryption flag it ignores ----
# The ZIP backend writes through libarchive straight to the file, bypassing the
# encrypting sink. --encrypt was accepted and had NO effect: exit 0, plain PK
# magic, and `unzip` recovered the plaintext with no key at all -- the exact
# outcome the design exists to prevent. Refusing is the safe answer, so these
# cases assert the refusal, and the last one asserts that nothing was written:
# a partial file would be worse than none, since it would look like output.
# ZIP 後端經由 libarchive 直接寫檔，繞過加密 sink。--encrypt 曾被接受且毫無作用：
# 離開碼 0、PK magic、`unzip` 完全無金鑰即可取回明文——正是本設計要防止的結果。
# 拒絕才是安全的答案，故以下案例斷言該拒絕，最後一項斷言未寫出任何檔案：半個檔案
# 比沒有更糟，因為它看起來像產出。
# Every case supplies a key. `--zip --encrypt` *without* one is a confounded
# test: it is refused even by a broken build, because the passphrase prompt
# rejects non-terminal stdin first. Measured -- that variant passed against the
# vulnerable binary, for the wrong reason. Only a keyed invocation reaches the
# ZIP path and proves anything.
# 每個案例都提供金鑰。不帶金鑰的 `--zip --encrypt` 是被混淆的測試：即使在有缺陷的
# 建置上也會被拒絕，因為密語提示會先擋下非終端機的 stdin。實測顯示該變體在有漏洞的
# binary 上「通過」了，但理由是錯的。只有帶金鑰的呼叫才會走到 ZIP 路徑並證明什麼。
for flags in "--zip --encrypt --keyfile $TMP/k.bin" "--zip --keyfile $TMP/k.bin" "--zip64 --encrypt --keyfile $TMP/k.bin"; do
  rm -f "$TMP/z.out"
  rc=0
  # shellcheck disable=SC2086
  "$ST" -c ${=flags} -f "$TMP/z.out" -C "$SRC" tree < /dev/null >/dev/null 2>&1 || rc=$?
  eq "'$flags' is refused" "1" "$rc"
  [ ! -e "$TMP/z.out" ] && ok "'$flags' writes no file" || bad "'$flags' writes no file"
done

# ...while each half on its own must still work.
# ……而兩者單獨使用時都必須仍然正常。
rc=0; "$ST" -c --zip -f "$TMP/plain.zip" -C "$SRC" tree >/dev/null 2>&1 || rc=$?
eq "--zip alone still works" "0" "$rc"
rc=0; "$ST" -c --encrypt --keyfile "$TMP/k.bin" -f "$TMP/tar.enc" -C "$SRC" tree >/dev/null 2>&1 || rc=$?
eq "tar --encrypt alone still works" "0" "$rc"

# And the encrypted tar must genuinely be unreadable without the key, which is
# the property the ZIP path silently lacked.
# 且加密後的 tar 必須真的在無金鑰時無法讀取——那正是 ZIP 路徑無聲缺少的性質。
rm -rf "$TMP/nokey"; mkdir -p "$TMP/nokey"
if "$ST" -x -f "$TMP/tar.enc" -C "$TMP/nokey" < /dev/null >/dev/null 2>&1; then
  bad "encrypted tar cannot be extracted without a key"
else
  ok "encrypted tar cannot be extracted without a key"
fi

# ---- round 24: reading a ZIP from stdin lost entries silently ----
# The README documents --zip as the way to read ZIP from a non-seekable stream.
# It did not work, and the damage varied with the input: a small archive failed
# outright, while a 300 KB one holding three files listed two entries and
# extracted exactly one -- exit 0 both times. libarchive was choosing its
# seekable ZIP reader, which wants a central directory it cannot seek to on a
# pipe. Both sizes are tested because one of them looked like a clean error and
# the other like success.
# README 記載 --zip 是從不可 seek 的串流讀取 ZIP 的方法。它並不管用，且損害隨輸入而
# 異：小型封存直接失敗，而一個含三個檔案的 300 KB 封存列出兩個項目、只解出一個檔案
# ——兩次離開碼皆為 0。原因是 libarchive 選用了 seekable ZIP reader，它需要 central
# directory，而在 pipe 上無法 seek 過去。兩種大小都要測，因為其中一種看起來像乾淨的
# 錯誤，另一種看起來像成功。
ZS="$TMP/zs"
mkdir -p "$ZS/s/sub"
printf 'a\n' > "$ZS/s/a.txt"
printf 'b\n' > "$ZS/s/sub/b.txt"
head -c 300000 /dev/urandom > "$ZS/s/big.bin"
( cd "$ZS" && "$ST" -c --zip -f "$TMP/big.zip" s ) >/dev/null 2>&1
mkdir -p "$ZS/small/sub"
printf 'a\n' > "$ZS/small/a.txt"
printf 'b\n' > "$ZS/small/sub/b.txt"
( cd "$ZS" && "$ST" -c --zip -f "$TMP/small.zip" small ) >/dev/null 2>&1

for z in big small; do
  want="$("$ST" -t --zip -f "$TMP/$z.zip" | wc -l | tr -d ' ')"
  got="$(cat "$TMP/$z.zip" | "$ST" -t --zip -f - | wc -l | tr -d ' ')"
  eq "-t --zip from stdin lists every entry ($z)" "$want" "$got"
done

# Extraction must produce the same tree from stdin as from a path. Counting
# entries is not enough on its own -- the listing could be right while the
# writes are not.
# 從 stdin 解出的樹必須與從路徑解出的相同。只數項目數並不足夠——列表可能正確而寫出
# 的內容不正確。
rm -rf "$TMP/zf" "$TMP/zp"; mkdir -p "$TMP/zf" "$TMP/zp"
"$ST" -x --zip -f "$TMP/big.zip" -C "$TMP/zf" >/dev/null 2>&1
cat "$TMP/big.zip" | "$ST" -x --zip -f - -C "$TMP/zp" >/dev/null 2>&1
if diff -r "$TMP/zf" "$TMP/zp" >/dev/null 2>&1; then
  ok "-x --zip from stdin matches extraction from a path"
else
  bad "-x --zip from stdin matches extraction from a path"
fi

# ---- reproducible output / 可重現的輸出 ----
# Not a defect -- a documented property that would break silently. The corpus
# must span more than one 4 MiB chunk or the -n arms have nothing to reorder and
# the check proves nothing. Encryption is asserted to be the opposite: an
# encrypted archive identical across runs would mean a reused nonce.
# 這不是缺陷，而是一項會無聲失效的既載性質。語料必須橫跨一個以上的 4 MiB 分塊，
# 否則各 -n 組別根本沒有東西可重排，該檢查也就證明不了任何事。加密則斷言相反的
# 性質：跨執行相同的加密封存意味著 nonce 被重複使用。
REPRO="$TMP/repro"
mkdir -p "$REPRO"
head -c 9000000 /dev/urandom > "$REPRO/big.bin"
printf 'small\n' > "$REPRO/a.txt"

for codec in "" "--zstd" "--gzip"; do
  base=""
  differing=0
  for n in 1 4 16; do
    # shellcheck disable=SC2086
    "$ST" -c ${=codec} -n "$n" -f "$TMP/r.out" -C "$REPRO" . >/dev/null 2>&1
    h="$(sha256sum < "$TMP/r.out" | cut -d' ' -f1)"
    if [ -z "$base" ]; then base="$h"; elif [ "$base" != "$h" ]; then differing=$((differing + 1)); fi
  done
  eq "output is byte-identical across -n (${codec:-plain tar})" "0" "$differing"
done

"$ST" -c --zstd -f "$TMP/run1" -C "$REPRO" . >/dev/null 2>&1
"$ST" -c --zstd -f "$TMP/run2" -C "$REPRO" . >/dev/null 2>&1
cmp -s "$TMP/run1" "$TMP/run2" \
  && ok "output is byte-identical across runs" \
  || bad "output is byte-identical across runs"

"$ST" -c --encrypt --keyfile "$TMP/k.bin" --zstd -f "$TMP/e1" -C "$REPRO" . >/dev/null 2>&1
"$ST" -c --encrypt --keyfile "$TMP/k.bin" --zstd -f "$TMP/e2" -C "$REPRO" . >/dev/null 2>&1
cmp -s "$TMP/e1" "$TMP/e2" \
  && bad "encrypted output differs across runs (nonce is not reused)" \
  || ok "encrypted output differs across runs (nonce is not reused)"

"$ST" --cat --keyfile "$TMP/k.bin" -f "$TMP/e1" > "$TMP/p1" 2>/dev/null
"$ST" --cat --keyfile "$TMP/k.bin" -f "$TMP/e2" > "$TMP/p2" 2>/dev/null
cmp -s "$TMP/p1" "$TMP/p2" \
  && ok "both encrypted runs decrypt to the same plaintext" \
  || bad "both encrypted runs decrypt to the same plaintext"

# ---- non-ASCII names must carry a pax "path" record ----
# pax records are defined to be UTF-8, so the record is what tells a reader the
# name is UTF-8 rather than bytes in some local code page. Without it a short
# non-ASCII name travels as bare ustar bytes and readers disagree: GNU tar passes
# them through, bsdtar on Windows decodes through the active code page and
# produced "unicode-Φ│çµûÖσñ╛" from "unicode-資料夾". The name is deliberately
# SHORT -- a long one gets a pax record anyway, and would pass without the fix.
# pax 記錄依規範即為 UTF-8，故該記錄正是「這個名稱是 UTF-8，而非某個本地碼頁的
# 位元組」的宣告。若缺少它，短的非 ASCII 名稱會以裸 ustar 位元組傳遞，各讀取器結論
# 不一：GNU tar 原樣通過，Windows 上的 bsdtar 以當前碼頁解碼，把 "unicode-資料夾"
# 解成 "unicode-Φ│çµûÖσñ╛"。此處的名稱刻意取短——長名稱本來就會附上 pax 記錄，
# 未修正時也會通過。
UNI2="$TMP/u2"
mkdir -p "$UNI2/src/unicode-資料夾"
printf 'unicode filename\n' > "$UNI2/src/unicode-資料夾/檔案.txt"
"$ST" -c -f "$TMP/u2.tar" -C "$UNI2" src >/dev/null 2>&1

rm -rf "$TMP/u2s"; mkdir -p "$TMP/u2s"
if "$ST" -x -f "$TMP/u2.tar" -C "$TMP/u2s" >/dev/null 2>&1 \
   && diff -r "$UNI2/src" "$TMP/u2s/src" >/dev/null 2>&1; then
  ok "non-ASCII names round-trip through swift_tar"
else
  bad "non-ASCII names round-trip through swift_tar"
fi

# The interoperability half: read it back with whichever system tar is present.
# On Windows prefer the OS-bundled bsdtar, which is the reader that used to get
# this wrong; a bare `tar` there is GNU tar, which passed even before the fix.
# 互通性的另一半：以現場可用的系統 tar 讀回。Windows 上優先採用作業系統內建的
# bsdtar，它正是過去會解錯的那個讀取器；該平台上的裸 `tar` 是 GNU tar，未修正前
# 也會通過。
# Note: no MSYS2_ARG_CONV_EXCL here. bsdtar is a native Windows binary, so it
# needs the MSYS runtime to rewrite these POSIX paths into Windows form; with
# conversion disabled it is handed "/tmp/..." and cannot open anything, which
# looks exactly like the interoperability failure this case is testing for.
# 注意：此處不設 MSYS2_ARG_CONV_EXCL。bsdtar 是原生 Windows 執行檔，需要 MSYS
# runtime 把這些 POSIX 路徑改寫為 Windows 形式；若停用轉換，它收到的是 "/tmp/…"
# 而完全開不了檔，其外觀與本案例要偵測的互通性失敗一模一樣。
ref_tar="$SYS_TAR"
[ -x /c/Windows/System32/tar.exe ] && ref_tar=/c/Windows/System32/tar.exe
rm -rf "$TMP/u2b"; mkdir -p "$TMP/u2b"
if "$ref_tar" -xf "$TMP/u2.tar" -C "$TMP/u2b" >/dev/null 2>&1 \
   && diff -r "$UNI2/src" "$TMP/u2b/src" >/dev/null 2>&1; then
  ok "non-ASCII names survive extraction by the system tar"
else
  bad "non-ASCII names survive extraction by the system tar"
fi


# ---- macOS round 7: ZIP must work at all, and flag its UTF-8 names ----
# Two failures in one place. `hdrcharset=UTF-8` was added to fix a Windows
# defect but was fatal when it failed, and libarchive implements it through
# iconv, which both build scripts disable -- so every ZIP write on macOS exited
# 1 producing nothing. Making it non-fatal restored writing but left general
# purpose bit 11 clear, because libarchive's other route to that flag asks
# nl_langinfo(CODESET), and a C program starts in the "C" locale. The names were
# correct UTF-8 either way; without the flag a reader has to guess, and Python's
# zipfile guessed wrong.
# 同一處的兩個失敗。`hdrcharset=UTF-8` 原是為修 Windows 缺陷而加，但失敗時視為致命，
# 而 libarchive 以 iconv 實作該選項、兩支建置腳本又都停用 iconv——於是 macOS 上所有
# ZIP 寫入都 exit 1 且不產生檔案。改為非致命後可寫了，但 general purpose bit 11 仍未
# 設定，因為 libarchive 通往該旗標的另一條路徑查的是 nl_langinfo(CODESET)，而 C 程式
# 啟動於 "C" locale。兩種情況下名稱都是正確的 UTF-8；少了旗標，讀取端只能猜，而
# Python 的 zipfile 猜錯了。
ZIPU="$TMP/zipu"
mkdir -p "$ZIPU/src"
printf 'x' > "$ZIPU/src/中文檔名.txt"
echo plain > "$ZIPU/src/a.txt"

if "$ST" -c --zip -f "$TMP/u.zip" -C "$ZIPU" src >/dev/null 2>&1; then
  ok "--zip produces an archive at all"
else
  bad "--zip produces an archive at all"
fi
if "$ST" -c --zip64 -f "$TMP/u64.zip" -C "$ZIPU" src >/dev/null 2>&1; then
  ok "--zip64 produces an archive at all"
else
  bad "--zip64 produces an archive at all"
fi

# Read the flag straight out of the local file headers rather than trusting any
# one reader: the point of the fix is what is IN the file.
# 直接自 local file header 讀出該旗標，而非採信任何單一讀取器：本修正的重點在於
# 檔案裡實際存了什麼。
if command -v python3 >/dev/null 2>&1 && [ -f "$TMP/u.zip" ]; then
  if python3 - "$TMP/u.zip" <<'PYEOF' >/dev/null 2>&1
import sys, struct
d = open(sys.argv[1], 'rb').read()
want = 'src/中文檔名.txt'.encode('utf-8')
off = 0
while True:
    i = d.find(b'PK\x03\x04', off)
    if i < 0:
        break
    flag = struct.unpack_from('<H', d, i + 6)[0]
    nlen = struct.unpack_from('<H', d, i + 26)[0]
    name = d[i + 30:i + 30 + nlen]
    if name == want:
        sys.exit(0 if flag & 0x800 else 1)
    off = i + 4
sys.exit(2)   # the entry was not found under its UTF-8 name
PYEOF
  then
    ok "ZIP sets general purpose bit 11 on a non-ASCII name"
  else
    bad "ZIP sets general purpose bit 11 on a non-ASCII name"
  fi

  # A reader that honours bit 11 must agree with what we wrote. Python's zipfile
  # is the discriminator: before the fix it returned a mojibake name here.
  # 遵守 bit 11 的讀取器必須與我們寫出的一致。Python 的 zipfile 是判別式：修正前
  # 它在此處回傳的是亂碼名稱。
  if python3 -c "
import sys, zipfile
want = 'src/中文檔名.txt'
sys.exit(0 if want in zipfile.ZipFile(sys.argv[1]).namelist() else 1)
" "$TMP/u.zip" >/dev/null 2>&1; then
    ok "an independent reader recovers the non-ASCII name from the ZIP"
  else
    bad "an independent reader recovers the non-ASCII name from the ZIP"
  fi
fi

# swift_tar must be able to read back what it wrote. Setting the flag only on
# the write side produced archives bsdtar could read and swift_tar could not.
# swift_tar 必須讀得回自己寫出的東西。只在寫入端設定旗標，會產出 bsdtar 讀得開而
# swift_tar 讀不開的封存。
rm -rf "$TMP/uz"; mkdir -p "$TMP/uz"
if "$ST" -x -f "$TMP/u.zip" -C "$TMP/uz" >/dev/null 2>&1 \
   && diff -r "$ZIPU/src" "$TMP/uz/src" >/dev/null 2>&1; then
  ok "swift_tar round-trips its own ZIP with a non-ASCII name"
else
  bad "swift_tar round-trips its own ZIP with a non-ASCII name"
fi

# ---- a missing -f archive: created by the appenders, refused by the rest ----
# Documented as a rule rather than two facts, so the test asserts the rule. The
# split is what makes a typo in the archive path catchable in one mode and
# silent in the other, which is the part a reader needs.
# 這是以規則而非兩則事實記載，故測試也斷言該規則。此分野決定了封存路徑打錯時，在某些
# 模式會被擋下、在另一些模式則無聲通過——那才是讀者需要知道的部分。
MA="$TMP/missing"
mkdir -p "$MA"
printf 'a\n' > "$MA/a.txt"

for mode in -r -u; do
  rm -f "$TMP/mk.tar"
  rc=0; "$ST" $mode -f "$TMP/mk.tar" -C "$MA" a.txt >/dev/null 2>&1 || rc=$?
  eq "$mode creates a missing archive" "0" "$rc"
  [ -s "$TMP/mk.tar" ] && ok "$mode leaves a non-empty archive" || bad "$mode leaves a non-empty archive"
done

rm -f "$TMP/none.tar"
rc=0; "$ST" --delete -f "$TMP/none.tar" a.txt >/dev/null 2>&1 || rc=$?
eq "--delete refuses a missing archive" "1" "$rc"
rc=0; "$ST" -t -f "$TMP/none.tar" >/dev/null 2>&1 || rc=$?
eq "-t refuses a missing archive" "1" "$rc"
[ ! -e "$TMP/none.tar" ] && ok "refusing modes create no archive" || bad "refusing modes create no archive"

# ---- repeated options: the first occurrence wins ----
# Documented because it is the opposite of the usual last-wins convention and
# nothing is reported when the later value is dropped. Asserted across three
# different options so the test pins the rule rather than one flag's quirk --
# it was found on -C alone, and only probing the neighbours showed it was general.
# 之所以記載，是因為它與一般「最後一個生效」的慣例相反，且捨棄較後的值時毫無提示。
# 此處跨三個不同選項斷言，使測試釘住的是規則而非單一旗標的怪癖——它最初是在 -C 上
# 發現的，探過鄰居才知道那是通則。
REP="$TMP/rep"
mkdir -p "$REP/c1" "$REP/c2"
printf 'from c1\n' > "$REP/c1/f.txt"
printf 'from c2\n' > "$REP/c2/f.txt"

"$ST" -c -f "$TMP/rep.tar" -C "$REP/c1" -C "$REP/c2" f.txt >/dev/null 2>&1
rm -rf "$TMP/repx"; mkdir -p "$TMP/repx"
"$ST" -x -f "$TMP/rep.tar" -C "$TMP/repx" >/dev/null 2>&1
eq "repeated -C: the first wins" "from c1" "$(cat "$TMP/repx/f.txt" 2>/dev/null)"

head -c 400000 /dev/urandom > "$REP/c1/big.bin"
"$ST" -c --zstd --zstd-level 1 --zstd-level 19 -f "$TMP/rl.tzst" -C "$REP/c1" big.bin >/dev/null 2>&1
"$ST" -c --zstd --zstd-level 1                 -f "$TMP/r1.tzst" -C "$REP/c1" big.bin >/dev/null 2>&1
cmp -s "$TMP/rl.tzst" "$TMP/r1.tzst" \
  && ok "repeated --zstd-level: the first wins" \
  || bad "repeated --zstd-level: the first wins"

rm -f "$TMP/rf1.tar" "$TMP/rf2.tar"
"$ST" -c -f "$TMP/rf1.tar" -f "$TMP/rf2.tar" -C "$REP/c1" f.txt >/dev/null 2>&1
[ -s "$TMP/rf1.tar" ] && [ ! -e "$TMP/rf2.tar" ] \
  && ok "repeated -f: the first wins, the second is not created" \
  || bad "repeated -f: the first wins, the second is not created"

# ---- the compress/.Z read filter ----
# Untested for the whole run because nothing obvious produces LZW: `compress` is
# absent, and `uncompress` here is gzip's decompressor in disguise (its
# --version reports "gunzip (gzip) 1.14"), which cannot write .Z at all. The
# producer that does exist is libarchive's own writer, reached through the
# Windows-bundled bsdtar -- which also makes it the right fixture, since this
# filter is a Swift port of libarchive's. Skipped rather than failed where no
# producer exists.
# 這條 filter 整輪都沒被測到，因為沒有明顯的 LZW 產生器：`compress` 不存在，而此處的
# `uncompress` 其實是 gzip 的解壓器偽裝（其 --version 回報「gunzip (gzip) 1.14」），
# 根本無法寫出 .Z。真正存在的產生器是 libarchive 自己的 writer，經由 Windows 內建的
# bsdtar 取用——這同時也讓它成為最恰當的測資，因為本 filter 正是 libarchive 對應
# 實作的 Swift 移植。無產生器的環境下跳過而非失敗。
# COPYFILE_DISABLE keeps macOS out of the fixture. bsdtar there writes an
# AppleDouble `._name` member beside every entry to carry extended attributes,
# and hides them again in its own listing -- so the archive holds 15 members
# where `bsdtar -tf` shows 8, and swift_tar, which does not hide them, extracts
# all 15. Both cases below then measure macOS's xattr convention instead of the
# thing they name. Windows cannot see this: there is no AppleDouble there.
# COPYFILE_DISABLE 讓 macOS 的特性不進入測資。該平台的 bsdtar 會在每個項目旁寫入
# AppleDouble 的 `._名稱` 成員以攜帶延伸屬性，並在自己的列表中再次隱藏它們——於是
# 封存實際有 15 個成員而 `bsdtar -tf` 只顯示 8 個，而不隱藏它們的 swift_tar 會把
# 15 個全部解出。下方兩個案例若不設定，量到的就會是 macOS 的 xattr 慣例，而非它們
# 各自宣稱要測的東西。Windows 上看不到此現象：那裡沒有 AppleDouble。
z_producer=""
if [ -x /c/Windows/System32/tar.exe ]; then z_producer=/c/Windows/System32/tar.exe
elif command -v bsdtar >/dev/null 2>&1; then z_producer=$(command -v bsdtar)
fi

if [ -n "$z_producer" ]; then
  ZS="$TMP/zsrc"
  mkdir -p "$ZS"
  printf 'alpha\n' > "$ZS/a.txt"
  head -c 30000 /dev/urandom > "$ZS/c.bin"
  printf 'u\n' > "$ZS/繁體.txt"
  COPYFILE_DISABLE=1 "$z_producer" -a -cf "$TMP/z.tar.Z" -C "$ZS" . >/dev/null 2>&1

  # 1f 9d is the LZW magic; if the producer quietly wrote something else the
  # rest of this block would be testing the wrong filter.
  # 1f 9d 是 LZW 的 magic；若產生器悄悄寫出別的格式，以下檢查就會在測錯的 filter。
  eq ".Z fixture really is LZW" "1f 9d" \
     "$(od -An -tx1 -N2 "$TMP/z.tar.Z" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')"

  rm -rf "$TMP/zout"; mkdir -p "$TMP/zout"
  if "$ST" -x -f "$TMP/z.tar.Z" -C "$TMP/zout" >/dev/null 2>&1 \
     && diff -r "$ZS" "$TMP/zout" >/dev/null 2>&1; then
    ok ".Z read filter extracts a libarchive-written archive"
  else
    bad ".Z read filter extracts a libarchive-written archive"
  fi
else
  echo "SKIP: .Z read filter (no LZW producer on this platform)"
fi

# ---- "--" ends the options ----
# A dash-leading filename was unarchivable by the obvious route: bare, it is read
# as a short-flag cluster and reports "unknown option -e", a flag this tool does
# not have; and "--", the POSIX escape every other tar accepts, was itself
# rejected as an unknown option. The fix has to cover the cluster expansion as
# well as the option check -- expansion runs first, so without it the name is
# already shredded before "--" is honoured.
# 以減號開頭的檔名，走顯而易見的路是封存不了的：裸寫會被讀成短旗標叢集並回報
# 「unknown option -e」——一個本工具並不存在的旗標；而 POSIX 的逃生口 "--"（其他 tar
# 都接受）本身又被當成未知選項拒絕。修正必須同時涵蓋叢集展開與選項檢查——展開先執行，
# 若不處理，檔名在 "--" 生效之前就已被拆散。
DASH="$TMP/dash"
mkdir -p "$DASH"
printf 'data\n' > "$DASH/-report.csv"
printf 'ok\n'   > "$DASH/normal.txt"

rc=0; "$ST" -c -f "$TMP/dash.tar" -C "$DASH" -- -report.csv normal.txt >/dev/null 2>&1 || rc=$?
eq "-- lets a dash-leading name be archived" "0" "$rc"
eq "-- archives every operand after it" "2" \
   "$("$ST" -t -f "$TMP/dash.tar" 2>/dev/null | wc -l | tr -d ' ')"

rm -rf "$TMP/dashx"; mkdir -p "$TMP/dashx"
if "$ST" -x -f "$TMP/dash.tar" -C "$TMP/dashx" >/dev/null 2>&1 \
   && cmp -s "$DASH/-report.csv" "$TMP/dashx/-report.csv"; then
  ok "-- round-trips the dash-leading name intact"
else
  bad "-- round-trips the dash-leading name intact"
fi

# The ./ form must keep working: it is the other way out, and the one that
# already worked before "--" existed.
# ./ 形式必須持續可用：那是另一條出路，也是 "--" 出現之前就已可行的那一條。
rc=0; "$ST" -c -f "$TMP/dot.tar" -C "$DASH" ./-report.csv >/dev/null 2>&1 || rc=$?
eq "./-name still archives a dash-leading name" "0" "$rc"

# ---- DOS reserved device names as member names ----
# Extracting an archive that holds a member called `nul` wrote six of seven files
# on Windows, dropped that one into the null device, and exited 0 with no message.
# GNU tar and bsdtar both produced seven from the same archive, and bsdtar is a
# native Windows binary too, so it was never a platform limitation -- swift_tar
# applied the \\?\ prefix only past MAX_PATH, and that prefix is also what turns
# off DOS device-name parsing.
#
# The fixture cannot be built on Windows: the OS refuses to create a file called
# `nul` in the first place. That is exactly the realistic shape of the bug -- an
# archive from a non-Windows sender -- so the fixture is built here only when a
# filesystem that permits the names is available, and skipped otherwise.
# 解出含名為 `nul` 之成員的封存時，Windows 上只寫出七個檔案中的六個，該檔被丟進空裝置，
# 且離開碼為 0、毫無訊息。GNU tar 與 bsdtar 對同一封存都產出七個，而 bsdtar 同樣是原生
# Windows 程式，故此非平台限制——swift_tar 僅在超過 MAX_PATH 時才套用 \\?\ 前綴，而該
# 前綴同時也是關閉 DOS 裝置名稱解析的機制。
#
# 測資無法在 Windows 上建立：作業系統根本不允許建立名為 `nul` 的檔案。這正是此缺陷的
# 真實形態——一個來自非 Windows 寄件者的封存——故僅在具備允許該類名稱之檔案系統時建立
# 測資，否則跳過。
dev_names=(con nul aux prn com1 lpt1 normal)
DEV="$TMP/dev"
mkdir -p "$DEV/src"
dev_ok=1
for n in $dev_names; do
  printf 'device-name test\n' > "$DEV/src/$n" 2>/dev/null || dev_ok=0
done

if [ "$dev_ok" -eq 1 ] && [ "$(ls "$DEV/src" | wc -l | tr -d ' ')" -eq ${#dev_names} ]; then
  ( cd "$DEV/src" && COPYFILE_DISABLE=1 "$SYS_TAR" -cf "$TMP/dev.tar" . ) >/dev/null 2>&1
  rm -rf "$TMP/devout"; mkdir -p "$TMP/devout"
  "$ST" -x -f "$TMP/dev.tar" -C "$TMP/devout" >/dev/null 2>&1
  eq "reserved device names all extract" "${#dev_names}" \
     "$(find "$TMP/devout" -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ -s "$TMP/devout/nul" ] \
    && ok "a member named 'nul' is a file, not the null device" \
    || bad "a member named 'nul' is a file, not the null device"
else
  echo "SKIP: reserved device names (this filesystem will not hold them)"
fi

# ---- extraction must not write outside the destination ----
# Only the POSIX "../" form was caught. Three other shapes wrote outside the -C
# directory with exit 0 and no message, because the guard split on "/" alone and
# never normalised what archiveName() normalises on the way in:
#   ..\..\x    one component to a "/"-split, so the ".." test saw no ".."
#   C:\...\x   no "/" at all, so the drive letter survived into the Windows layer
#   /tmp/x     leading "/" stripped, yet still resolved outside the destination
# An archive is not required to have been written by this tool, so the read side
# has to assume the name is hostile. No tar CLI will create these names, hence
# the raw-header helper.
# 原本只有 POSIX 的 "../" 形式被擋下。另外三種形態會寫到 -C 目錄之外，且離開碼為 0、
# 毫無訊息，原因是守門僅以 "/" 分割，且未做 archiveName() 在寫入端所做的正規化：
#   ..\..\x    對「僅以 / 分割」而言是單一組件，".." 的檢查看不到 ".."
#   C:\...\x   完全不含 "/"，磁碟機代號因而存活至 Windows 層
#   /tmp/x     開頭的 "/" 雖被去除，結果仍解析到目的地之外
# 封存不保證由本工具寫出，故讀取端必須假設名稱懷有敵意。沒有任何 tar CLI 會建立這類
# 名稱，因此需要 raw header 產生器。
# The generator is tracked in the repo, so "missing" is never an environment
# condition -- it means the path is wrong, which is exactly what fc60861 found.
# Both guarded blocks therefore fail rather than skip. flow.md records the reason
# as a rule: a SKIP never becomes a FAIL, so nobody reports it.
# 產生器是 repo 追蹤的檔案，故「找不到」絕不是環境條件，而是路徑寫錯——fc60861 找到的
# 正是這個。兩個受守門的區塊因此改為失敗而非跳過。flow.md 已將理由記為常規：SKIP 永遠
# 不會變成 FAIL，因此無人回報。
RAW="${0:A:h:h}/verifications/make_raw_tar.zsh"
if [ -f "$RAW" ]; then
  TRAV="$TMP/trav"
  mkdir -p "$TRAV"

  # name, must-not-appear-at, label
  esc_fail=0
  check_traversal() {
    local member=$1 outside=$2 label=$3
    zsh "$RAW" "$TMP/trav.tar" "$member" 'traversal payload' >/dev/null 2>&1
    rm -rf "$TRAV/a"; mkdir -p "$TRAV/a/b"
    rm -f "$outside"
    ( cd "$TRAV/a/b" && "$ST" -x -f "$TMP/trav.tar" ) >/dev/null 2>&1
    # Nothing may appear above the extraction directory, nor at an absolute path.
    # 解出目錄之上不得出現任何東西，絕對路徑處亦然。
    local above
    above=$(find "$TRAV" -type f -not -path "$TRAV/a/b/*" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$above" -ne 0 ] || [ -e "$outside" ]; then
      bad "traversal blocked: $label"
      esc_fail=$((esc_fail + 1))
    else
      ok "traversal blocked: $label"
    fi
    rm -f "$outside" 2>/dev/null
  }

  check_traversal '../../escaped.txt'            "$TMP/never_posix"   '../ (posix)'
  check_traversal '..\..\escaped.txt'            "$TMP/never_back"    '..\ (backslash)'
  check_traversal 'ok/../../escaped.txt'         "$TMP/never_mixed"   'interior ../'
  check_traversal '/tmp/swift_tar_abs_probe.txt' /tmp/swift_tar_abs_probe.txt      'absolute posix'
  check_traversal 'C:\Windows\Temp\st_abs.txt'   /c/Windows/Temp/st_abs.txt        'absolute windows'

  # Two entries: a symlink out of the tree, then a member written through it.
  # Neither name contains ".." once the link is resolved, so the name-only check
  # above passes both while the write lands outside. GNU tar 1.35 refuses this;
  # bsdtar 3.8.4 does not, so matching bsdtar was never sufficient.
  # 兩個項目：一個指向樹外的 symlink，接著一個穿過它寫入的成員。連結解析後兩者名稱皆
  # 不含 ".."，故上方僅檢查名稱的機制會讓兩者通過，而寫入卻落在外面。GNU tar 1.35
  # 拒絕此組合，bsdtar 3.8.4 不拒絕，故「與 bsdtar 一致」從來就不足夠。
  # The jail is three levels deep so "../../.." lands exactly on $TRAV/p -- the
  # search therefore has to start at $TRAV/p, not below it. An earlier version
  # searched $TRAV/p's subtree only and passed against the vulnerable binary:
  # the escaped file was sitting one directory above where it was looking.
  # 監獄有三層深，故 "../../.." 恰好落在 $TRAV/p——因此搜尋必須自 $TRAV/p 起算，而非
  # 其下。先前的版本只搜尋 $TRAV/p 的子樹，結果對有漏洞的 binary 也通過：逃出去的檔案
  # 就位在它搜尋範圍上方一層。
  zsh "$RAW" "$TMP/portal.tar" link portal '../../..' file 'portal/pwned.txt' 'PWNED' >/dev/null 2>&1
  rm -rf "$TRAV/p"; mkdir -p "$TRAV/p/a/b"
  rm -f "$TRAV/p/pwned.txt" "$TRAV/pwned.txt" "$TMP/pwned.txt"
  ( cd "$TRAV/p/a/b" && "$ST" -x -f "$TMP/portal.tar" ) >/dev/null 2>&1
  if [ ! -e "$TRAV/p/pwned.txt" ] && [ ! -e "$TRAV/pwned.txt" ] && [ ! -e "$TMP/pwned.txt" ]; then
    ok "traversal blocked: write through a planted symlink"
  else
    bad "traversal blocked: write through a planted symlink"
  fi

  # A hardlink aimed outside is refused safely, but used to be refused in total
  # silence: no stdout, no stderr, exit 0, entry gone. The same tool already
  # warned when a hardlink target was merely missing, so the security-relevant
  # case was the quiet one. Assert the message, not just the absence of a file.
  # 指向外部的硬連結會被安全地拒絕，但過去是「完全沉默地」拒絕：無 stdout、無 stderr、
  # 離開碼 0、項目消失。同一支程式對「目標僅是不存在」的硬連結早已會警告，於是與安全
  # 相關的那個案例反而是沉默的那個。此處斷言訊息本身，而非僅斷言檔案不存在。
  zsh "$RAW" "$TMP/hard.tar" hard stolen.txt '../../../secret_outside.txt' >/dev/null 2>&1
  rm -rf "$TRAV/h"; mkdir -p "$TRAV/h/a/b"
  hard_out=$( cd "$TRAV/h/a/b" && "$ST" -x -f "$TMP/hard.tar" 2>&1 )
  case $hard_out in
    *"skipping hardlink"*) ok "an unsafe hardlink target is reported, not dropped in silence" ;;
    *) bad "an unsafe hardlink target is reported, not dropped in silence" ;;
  esac

  # The same write-through attack, with the portal built by the two override
  # mechanisms rather than a plain symlink header: a pax "linkpath" record and a
  # GNU 'K' long-link entry. Both are separate parse paths, and the guard covers
  # them because it runs at write time rather than while parsing a name -- worth
  # pinning, since a refactor that moved the check into name handling would pass
  # the plain case and reopen these two. bsdtar escapes on both.
  # 同一個穿透寫入攻擊，但 portal 改由兩種覆寫機制建立，而非單純的 symlink 標頭：
  # pax 的 "linkpath" 記錄與 GNU 的 'K' 長連結項目。兩者是各自獨立的解析路徑，而守門
  # 之所以涵蓋它們，是因為它在寫入時執行、而非在解析名稱時——值得釘住，因為若有人重構
  # 把檢查移進名稱處理，單純案例仍會通過，這兩條卻會重新打開。bsdtar 兩者皆逃逸。
  for mech in pax gnu; do
    if [ "$mech" = pax ]; then
      zsh "$RAW" "$TMP/ovr.tar" pax 'PaxHeaders/p' 'linkpath=../../..' \
          link portal placeholder file 'portal/pwned_ovr.txt' 'PWNED' >/dev/null 2>&1
    else
      zsh "$RAW" "$TMP/ovr.tar" gnulink './@LongLink' '../../..' \
          link portal placeholder file 'portal/pwned_ovr.txt' 'PWNED' >/dev/null 2>&1
    fi
    rm -rf "$TRAV/o"; mkdir -p "$TRAV/o/a/b"
    rm -f "$TRAV/o/pwned_ovr.txt" "$TRAV/pwned_ovr.txt" "$TMP/pwned_ovr.txt"
    ( cd "$TRAV/o/a/b" && "$ST" -x -f "$TMP/ovr.tar" ) >/dev/null 2>&1
    if [ ! -e "$TRAV/o/pwned_ovr.txt" ] && [ ! -e "$TRAV/pwned_ovr.txt" ] && [ ! -e "$TMP/pwned_ovr.txt" ]; then
      ok "traversal blocked: portal via $mech override"
    else
      bad "traversal blocked: portal via $mech override"
    fi
  done

  # ...and a legitimate symlink must still survive, or the guard is too blunt.
  # ……而合法的 symlink 必須仍然存活，否則這道守門就過度阻擋了。
  zsh "$RAW" "$TMP/legit.tar" file 'lib/real.so' 'REAL' link 'lib/alias.so' 'real.so' >/dev/null 2>&1
  rm -rf "$TRAV/legit"; mkdir -p "$TRAV/legit"
  "$ST" -x -f "$TMP/legit.tar" -C "$TRAV/legit" >/dev/null 2>&1
  [ -e "$TRAV/legit/lib/real.so" ] && [ -e "$TRAV/legit/lib/alias.so" ] \
    && ok "a legitimate symlink still extracts" \
    || bad "a legitimate symlink still extracts"
else
  bad "path traversal (missing fixture generator $RAW)"
fi

# ---- a "./" member must not crash extraction ----
# `tar -C dir .` puts "./" first in the archive, and extracting such an archive
# without -C died with an illegal instruction (exit 132), no message, no files.
# Any -C masked it, including `-C .`, so the failure appeared only in the
# plainest command there is: swift_tar -x -f archive.tar. The extraction below
# therefore deliberately uses no -C; adding one would make this test pass
# against the broken binary.
# `tar -C dir .` 會把 "./" 放在封存最前面，而解出這類封存時若不加 -C，會以非法指令
# 死亡（離開碼 132），無訊息、無檔案。任何 -C 都會掩蓋它，連 `-C .` 也一樣，故該失敗
# 只出現在最單純的指令上：swift_tar -x -f archive.tar。因此以下解出刻意不使用 -C；
# 加上去會讓這個測試對壞掉的 binary 也通過。
DOT="$TMP/dotsrc"
mkdir -p "$DOT/sub"
printf 'a\n' > "$DOT/a.txt"
printf 'b\n' > "$DOT/sub/b.txt"
( cd "$DOT" && "$ST" -c -f "$TMP/dot.tar" -C "$DOT" . ) >/dev/null 2>&1

rm -rf "$TMP/dotout"; mkdir -p "$TMP/dotout"
dot_rc=0
( cd "$TMP/dotout" && "$ST" -x -f "$TMP/dot.tar" ) >/dev/null 2>&1 || dot_rc=$?
eq "a './' member extracts without crashing" "0" "$dot_rc"
eq "a './' archive yields every member" "2" \
   "$(find "$TMP/dotout" -type f 2>/dev/null | wc -l | tr -d ' ')"

# ...and the "./" entry must not be reported as unsafe. It names the destination
# itself; a security-shaped warning on almost every archive is how real ones get
# ignored.
# ……且 "./" 項目不得被回報為不安全。它指的就是目的地本身；在幾乎每個封存上都掛一則
# 安全性質的警告，正是真警告被忽略的原因。
rm -rf "$TMP/dotout2"; mkdir -p "$TMP/dotout2"
dot_err=$( cd "$TMP/dotout2" && "$ST" -x -f "$TMP/dot.tar" 2>&1 )
case $dot_err in
  *unsafe*) bad "a './' member is not called unsafe" ;;
  *) ok "a './' member is not called unsafe" ;;
esac

# ---- case collisions within one extraction ----
# An archive from a case-sensitive filesystem can hold file.txt and File.txt.
# On a case-folding destination the second silently destroyed the first: exit 0,
# no message, one file where the archive had two. Extraction now refuses unless
# --force. The fixture is built with the raw-header helper because no tar CLI on
# a case-insensitive filesystem can create both names to archive them.
# 來自區分大小寫檔案系統的封存可同時持有 file.txt 與 File.txt。在會摺疊大小寫的目的地
# 上，後者會無聲摧毀前者：離開碼 0、無訊息、封存有兩個而磁碟只剩一個。解出現已拒絕，
# 除非加上 --force。測資以 raw header 產生器建立，因為在不區分大小寫的檔案系統上，沒有
# 任何 tar CLI 能先造出這兩個名稱再打包。
if [ -f "$RAW" ]; then
  zsh "$RAW" "$TMP/case.tar" file file.txt LOWER file File.txt UPPER >/dev/null 2>&1
  rm -rf "$TMP/caseout"; mkdir -p "$TMP/caseout"
  case_rc=0
  ( cd "$TMP/caseout" && "$ST" -x -f "$TMP/case.tar" ) >/dev/null 2>&1 || case_rc=$?
  landed="$(ls "$TMP/caseout" | wc -l | tr -d ' ')"

  if [ "$landed" -eq 2 ]; then
    # Case-sensitive destination: both names are distinct files and the guard
    # must stay out of the way entirely.
    # 區分大小寫的目的地：兩個名稱是相異檔案，此守門必須完全不介入。
    eq "case-sensitive destination: both members extract" "0" "$case_rc"
  else
    eq "case collision is refused without --force" "1" "$case_rc"

    rm -rf "$TMP/caseforce"; mkdir -p "$TMP/caseforce"
    force_rc=0
    ( cd "$TMP/caseforce" && "$ST" -x -f "$TMP/case.tar" --force ) >/dev/null 2>&1 || force_rc=$?
    eq "--force allows the collision" "0" "$force_rc"
  fi

  # A genuine duplicate -- the same spelling twice -- is legal tar and must keep
  # working: last copy wins, no refusal. The guard keys on a folded match with a
  # *different* spelling precisely so this case is untouched.
  # 真正的同名成員——相同拼法出現兩次——是合法的 tar，必須維持可用：最後一份勝出、不得
  # 拒絕。此守門以「摺疊後相同但拼法不同」為條件，正是為了不影響這個情形。
  zsh "$RAW" "$TMP/dup2.tar" file dup.txt FIRST file dup.txt SECOND >/dev/null 2>&1
  rm -rf "$TMP/dupout"; mkdir -p "$TMP/dupout"
  dup_rc=0
  ( cd "$TMP/dupout" && "$ST" -x -f "$TMP/dup2.tar" ) >/dev/null 2>&1 || dup_rc=$?
  eq "a genuine duplicate name still extracts" "0" "$dup_rc"
  eq "a genuine duplicate keeps the last copy" "SECOND" "$(cat "$TMP/dupout/dup.txt" 2>/dev/null)"
fi

# ---- input shorter than one header block is not an empty archive ----
# Zero bytes is an empty archive by convention, and bsdtar agrees. A short run of
# arbitrary bytes is not, but was read the same way: nothing examined, no output,
# exit 0 -- an unrecognised file passing for a valid one.
# 零位元組依慣例是空封存，bsdtar 亦同。一小段任意位元組則不是，但先前被以相同方式看待：
# 不檢查任何東西、無輸出、離開碼 0——一個無法辨識的檔案被當成合法封存。
: > "$TMP/empty.bin"
rc=0; "$ST" -t -f "$TMP/empty.bin" >/dev/null 2>&1 || rc=$?
eq "an empty file is an empty archive" "0" "$rc"

for n in 100 511; do
  head -c "$n" /dev/urandom > "$TMP/short.bin"
  rc=0; "$ST" -t -f "$TMP/short.bin" >/dev/null 2>&1 || rc=$?
  eq "$n random bytes is not an empty archive" "1" "$rc"
done

# ---- a destination that is not a regular file is replaced, not written through ----
# Opening a FIFO for writing blocks until a reader appears, so extracting a
# regular member onto an existing pipe hung forever instead of failing: measured
# rc=124 under a 10 s timeout where GNU tar finished in 110 ms. A pre-existing
# pipe suffices; the archive need not be hostile. The timeout is the assertion
# here -- without it a regression does not fail the suite, it stops it.
# 對 FIFO 開啟寫入會阻塞到有讀者出現，因此把一般成員解到既有管線上不是失敗、而是
# 永久卡住：實測 10 秒 timeout 下 rc=124，而 GNU tar 只花 110 ms。只要有一個既存
# 管線就會觸發，封存不必有惡意。此處的斷言就是那個 timeout——沒有它，回歸不會讓
# 測試失敗，而是讓測試停住。
if command -v mkfifo >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 &&
   mkfifo "$TMP/probe.fifo" 2>/dev/null; then
  rm -f "$TMP/probe.fifo"
  mkdir -p "$TMP/fifosrc" && printf 'content\n' > "$TMP/fifosrc/member.txt"
  "$ST" -c -f "$TMP/fifo.tar" -C "$TMP/fifosrc" . >/dev/null 2>&1
  mkdir -p "$TMP/fifoout" && mkfifo "$TMP/fifoout/member.txt"
  rc=0; timeout 10 "$ST" -x -f "$TMP/fifo.tar" -C "$TMP/fifoout" >/dev/null 2>&1 || rc=$?
  eq "extracting onto an existing FIFO does not hang" "0" "$rc"
  if [ -p "$TMP/fifoout/member.txt" ]; then
    bad "the FIFO is replaced by the archived regular file"
  else
    eq "the FIFO is replaced by the archived regular file" \
       "content" "$(cat "$TMP/fifoout/member.txt" 2>/dev/null)"
  fi

  # ---- FIFO members round-trip ----
  # mkfifo needs no privilege on any POSIX system, so a FIFO entry can always be
  # restored -- unlike a device node, which needs root. Both directions are
  # checked, because storing and restoring are separate branches: the writer
  # used to drop the entry with "skipping special file" and the reader with
  # "skipping type '6' entry", so an archive could lose its pipes at either end.
  # 任何 POSIX 系統上的 mkfifo 都不需權限，故 FIFO 項目必定還原得回來——這與需要
  # root 的裝置節點不同。兩個方向都要檢查，因為存入與還原是各自獨立的分支：寫入端
  # 原本以「skipping special file」丟棄該項目，讀取端則以「skipping type '6' entry」
  # 丟棄，因此封存在任一端都可能失去它的管線。
  mkdir -p "$TMP/fifosrc2" && mkfifo "$TMP/fifosrc2/pipe"
  printf 'plain\n' > "$TMP/fifosrc2/normal.txt"
  "$ST" -c -f "$TMP/rt.tar" -C "$TMP/fifosrc2" . >/dev/null 2>&1
  eq "a FIFO is listed in an archive we wrote" \
     "1" "$("$ST" -t -f "$TMP/rt.tar" 2>/dev/null | grep -c 'pipe')"
  mkdir -p "$TMP/rtout"
  rc=0; "$ST" -x -f "$TMP/rt.tar" -C "$TMP/rtout" >/dev/null 2>&1 || rc=$?
  eq "extracting a FIFO member succeeds" "0" "$rc"
  [ -p "$TMP/rtout/pipe" ] && ok "a FIFO member is restored as a FIFO" \
                           || bad "a FIFO member is restored as a FIFO"

  # mkfifo's mode argument is masked by umask exactly as open's is, so without
  # an explicit chmod a 0666 pipe arrives as 0666 & ~umask. Forcing a umask that
  # would bite makes the difference visible; 0600 has no bits umask can clear,
  # so 0666 is the mode that actually tests this.
  # mkfifo 的 mode 參數與 open 一樣會被 umask 遮罩，故若無明確的 chmod，0666 的管線
  # 會變成 0666 & ~umask。刻意設一個會咬到的 umask 才看得出差別；0600 沒有 umask
  # 清得掉的位元，因此 0666 才是真正能測到這件事的權限。
  rm -rf "$TMP/msrc" "$TMP/mout"
  mkdir -p "$TMP/msrc" && mkfifo -m 0666 "$TMP/msrc/p666"
  "$ST" -c -f "$TMP/m.tar" -C "$TMP/msrc" . >/dev/null 2>&1
  mkdir -p "$TMP/mout"
  ( umask 077; "$ST" -x -f "$TMP/m.tar" -C "$TMP/mout" >/dev/null 2>&1 )
  # The leading 'p' is part of the assertion: it says the entry is a FIFO, so
  # one comparison covers both the type and the mode.
  # 開頭的 'p' 也是斷言的一部分：它表示該項目是 FIFO，故一次比對同時涵蓋型別與權限。
  eq "a FIFO's mode survives umask" \
     "prw-rw-rw-" "$(ls -l "$TMP/mout/p666" 2>/dev/null | cut -c1-10)"

  # Interoperability both ways: a pipe written by GNU tar must come back as a
  # pipe here, and one written here must come back as a pipe under GNU tar.
  # 雙向互通：GNU tar 寫出的管線在此必須還原為管線，此處寫出的在 GNU tar 下亦然。
  if command -v "$SYS_TAR" >/dev/null 2>&1; then
    rm -rf "$TMP/gout" "$TMP/sout"
    "$SYS_TAR" -c -f "$TMP/gnu.tar" -C "$TMP/fifosrc2" . 2>/dev/null
    mkdir -p "$TMP/gout"
    "$ST" -x -f "$TMP/gnu.tar" -C "$TMP/gout" >/dev/null 2>&1
    [ -p "$TMP/gout/pipe" ] && ok "a FIFO from the system tar extracts as a FIFO" \
                            || bad "a FIFO from the system tar extracts as a FIFO"
    mkdir -p "$TMP/sout"
    "$SYS_TAR" -x -f "$TMP/rt.tar" -C "$TMP/sout" 2>/dev/null
    [ -p "$TMP/sout/pipe" ] && ok "the system tar reads back a FIFO we wrote" \
                            || bad "the system tar reads back a FIFO we wrote"
  else
    echo "SKIP: FIFO interoperability (no system tar)"
  fi
else
  echo "SKIP: FIFO tests (need mkfifo and timeout)"
fi

# ---- a read-only destination is replaced, and later members still land ----
# Write permission on a file is not needed to replace it, only on its directory.
# Opening 0444 for writing gives EACCES, which aborted the whole extract: found
# against the claw-code corpus, where git stores loose objects 0444, so
# re-extracting any tree holding a .git stopped at the first object (errno 13)
# while GNU tar completed. Windows enforces the attribute on delete too, so
# clearing it -- not unlinking -- is the fix there; bsdtar does unlink and so
# reports "Can't unlink already-existing object".
#
# This must NOT sit behind the mkfifo guard above. It did, for one commit, and
# Windows -- which has no mkfifo -- skipped it and shipped the defect: the
# round 49 blind test found the Windows path still aborting after the POSIX one
# was fixed. A test that the affected platform silently skips is not coverage.
#
# 取代一個檔案不需要對該檔有寫入權，只需要對其目錄有。以寫入開啟 0444 會得到
# EACCES，並使整個解壓中止：以 claw-code 語料發現，git 的鬆散物件為 0444，因此
# 重新解出任何含 .git 的樹都會停在第一個物件（errno 13），而 GNU tar 能完成。
# Windows 在刪除時同樣強制該屬性，故該平台的修法是清除屬性而非 unlink；bsdtar
# 採 unlink，因而回報 "Can't unlink already-existing object"。
#
# 此段**不可**放在上方的 mkfifo 守衛之內。它曾如此放置一個提交之久，而沒有 mkfifo
# 的 Windows 便跳過它並帶著缺陷出貨：round 49 盲測發現 POSIX 端修好之後，Windows
# 端仍會中止。一個會被受影響平台靜默跳過的測試不算涵蓋。
mkdir -p "$TMP/rosrc"
printf 'content\n' > "$TMP/rosrc/aa.txt"
printf 'content\n' > "$TMP/rosrc/mm.txt"
printf 'content\n' > "$TMP/rosrc/zz.txt"
"$ST" -c -f "$TMP/ro.tar" -C "$TMP/rosrc" . >/dev/null 2>&1
mkdir -p "$TMP/roout"
for f in aa mm zz; do printf 'stale\n' > "$TMP/roout/$f.txt"; done
chmod 0444 "$TMP/roout/mm.txt"
rc=0; "$ST" -x -f "$TMP/ro.tar" -C "$TMP/roout" >/dev/null 2>&1 || rc=$?
eq "a read-only destination does not abort the extract" "0" "$rc"
eq "a read-only destination is overwritten" \
   "content" "$(cat "$TMP/roout/mm.txt" 2>/dev/null)"
# The member sorted after the read-only one is the one that was silently left
# stale, so it is the check that matters most.
# 排在唯讀成員之後的那個，正是先前被靜默留在舊內容的檔案，故此檢查最關鍵。
eq "a member after the read-only one still extracts" \
   "content" "$(cat "$TMP/roout/zz.txt" 2>/dev/null)"

# ---- -C must not destroy an existing file ----
# `-C notes.txt` instead of `-C notes/` is an ordinary typo. Measured before the
# fix: the file was replaced by a directory and the run exited 0, with no output
# at all -- silent destruction of data the archive never claimed. Both reference
# tars refuse and leave the file alone (bsdtar "could not chdir to '<path>'",
# GNU tar "Cannot open: Not a directory").
#
# The mechanism is worth knowing, because it is the cost of an earlier fix: the
# tar path folds -C into each member's path rather than chdir()ing, so the -C
# target arrives at the parent-creation step looking like an ordinary parent
# directory to be made, and clearing a non-directory that blocks a directory is
# correct there -- for names the archive claims. The destination root is not one
# of those. It is checked up front now, and ensureDirectory additionally refuses
# to clear the root itself.
#
# `-C notes/` 打成 `-C notes.txt` 是尋常的打字錯誤。修正前實測：該檔案被目錄取代、
# 執行以 0 結束、完全沒有輸出——無聲地摧毀了封存從未聲稱過的資料。兩個參照實作都拒絕
# 並保留該檔案（bsdtar 為 "could not chdir to '<path>'"，GNU tar 為
# "Cannot open: Not a directory"）。
#
# 其成因值得記，因為它是先前一項修正的代價：tar 路徑是把 -C 併入每個成員的路徑而非
# chdir()，故 -C 目標會以「一個待建立的普通父目錄」的樣貌抵達父目錄建立那一步，而在
# 該處清除擋住目錄的非目錄是正確的——對封存所聲稱的名稱而言。目的地根目錄不屬於那一類。
# 現在於前方檢查，且 ensureDirectory 另外拒絕清除根目錄本身。
mkdir -p "$TMP/cdest"
printf 'PRECIOUS\n' > "$TMP/cdest/victim.txt"
"$ST" -c -f "$TMP/cdest/src.tar" -C "$TMP/fdsrc" . >/dev/null 2>&1 || \
  { mkdir -p "$TMP/cdsrc" && printf 'payload\n' > "$TMP/cdsrc/p.txt" && \
    "$ST" -c -f "$TMP/cdest/src.tar" -C "$TMP/cdsrc" . >/dev/null 2>&1; }
rc=0; "$ST" -x -f "$TMP/cdest/src.tar" -C "$TMP/cdest/victim.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && ok "-C pointing at a file ends the run non-zero" \
                || bad "-C pointing at a file ends the run non-zero (got rc=0)"
[ -f "$TMP/cdest/victim.txt" ] && ok "-C pointing at a file leaves the file alone" \
                               || bad "-C pointing at a file leaves the file alone (it was destroyed)"
eq "the file's content is untouched" \
   "PRECIOUS" "$(cat "$TMP/cdest/victim.txt" 2>/dev/null)"
# The documented behaviour on the other side of the same flag must survive:
# a -C directory that does not exist is still created.
# 同一個旗標另一側的既有文件行為必須維持：不存在的 -C 目錄仍會被建立。
rc=0; "$ST" -x -f "$TMP/cdest/src.tar" -C "$TMP/cdest/made/deep" >/dev/null 2>&1 || rc=$?
eq "a missing -C directory is still created" "0" "$rc"
[ -d "$TMP/cdest/made/deep" ] && ok "the missing -C directory really exists" \
                              || bad "the missing -C directory really exists"

# ---- a plain file where the archive holds a directory is replaced ----
# A project whose `config` file becomes a `config/` directory is an ordinary
# event, not an edge case. Both reference tars replace the file: measured on one
# archive, bsdtar and GNU tar each ended 0 with `config` a directory, while this
# tool ended 1 with the member unwritten, reporting errno 2 -- ENOENT, which
# named neither the occupied path nor the fact that anything occupied it.
# Refusing was an omission rather than a policy: extraction already replaces a
# read-only file, a FIFO and a symlink at a destination.
# The members either side of the conflict are checked too, because "the rest of
# the archive still lands" is the half a failing extraction most often loses.
#
# 一個專案的 `config` 檔案演變成 `config/` 目錄是尋常事件，不是邊界案例。兩個參照實作
# 都會取代該檔案：以同一份封存實測，bsdtar 與 GNU tar 皆以 0 結束且 `config` 成為目錄，
# 而本工具以 1 結束、成員未寫入，並回報 errno 2——ENOENT，既沒指出被占用的路徑，也沒
# 說明有東西占用了它。拒絕並非政策而是遺漏：解出時本就會取代目的地上的唯讀檔案、FIFO
# 與 symlink。衝突兩側的成員一併檢查，因為「封存其餘部分仍會落地」正是失敗的解出最常
# 丟掉的那一半。
mkdir -p "$TMP/fdsrc/config"
printf 'new aa\n'     > "$TMP/fdsrc/aa.txt"
printf 'new conf\n'   > "$TMP/fdsrc/config/a.conf"
printf 'new zz\n'     > "$TMP/fdsrc/zz.txt"
"$ST" -c -f "$TMP/fd.tar" -C "$TMP/fdsrc" . >/dev/null 2>&1
mkdir -p "$TMP/fdout"
printf 'old aa\n'     > "$TMP/fdout/aa.txt"
printf 'old config\n' > "$TMP/fdout/config"     # a plain FILE where a dir is wanted
printf 'old zz\n'     > "$TMP/fdout/zz.txt"
rc=0; "$ST" -x -f "$TMP/fd.tar" -C "$TMP/fdout" >/dev/null 2>&1 || rc=$?
eq "a file where a directory is wanted does not fail the run" "0" "$rc"
[ -d "$TMP/fdout/config" ] && ok "the blocking file becomes a directory" \
                           || bad "the blocking file becomes a directory"
eq "the directory's member is written" \
   "new conf" "$(cat "$TMP/fdout/config/a.conf" 2>/dev/null)"
eq "the member before the conflict is refreshed" \
   "new aa" "$(cat "$TMP/fdout/aa.txt" 2>/dev/null)"
eq "the member after the conflict is refreshed" \
   "new zz" "$(cat "$TMP/fdout/zz.txt" 2>/dev/null)"

# The same conflict one level up: the blocker is an interior component, so the
# exact-name check does not see it and the component walk has to.
# 同樣的衝突發生在上一層：阻礙者是中間段，逐名比對看不到它，必須靠逐段走訪處理。
mkdir -p "$TMP/deepsrc/a/b"
printf 'deep\n' > "$TMP/deepsrc/a/b/c.txt"
"$ST" -c -f "$TMP/deep.tar" -C "$TMP/deepsrc" . >/dev/null 2>&1
mkdir -p "$TMP/deepout"
printf 'blocker\n' > "$TMP/deepout/a"           # a FILE two levels above the member
rc=0; "$ST" -x -f "$TMP/deep.tar" -C "$TMP/deepout" >/dev/null 2>&1 || rc=$?
eq "an interior blocking file does not fail the run" "0" "$rc"
eq "a member below an interior blocker is written" \
   "deep" "$(cat "$TMP/deepout/a/b/c.txt" 2>/dev/null)"

# ---- a symlink at the final component is replaced, not written through ----
# The traversal tests above cover a symlink among the *parent* components. A
# symlink at the member's own name is a different case: `open` follows it, so
# without the unlink the member's bytes land on the link's target, outside the
# destination, while the destination keeps a link that looks harmless.
# 上方的穿透測試涵蓋的是位於**上層**元件的 symlink。位於成員自身名稱上的 symlink
# 是另一回事：`open` 會跟隨它，因此若不先 unlink，成員的內容會落在連結目標上——
# 在目的地之外——而目的地留下的是一個看似無害的連結。
mkdir -p "$TMP/lnout"
printf 'untouched\n' > "$TMP/lntarget.txt"
if ln -s "$TMP/lntarget.txt" "$TMP/lnout/mm.txt" 2>/dev/null; then
  rc=0; "$ST" -x -f "$TMP/ro.tar" -C "$TMP/lnout" >/dev/null 2>&1 || rc=$?
  eq "a symlink destination does not divert the member" \
     "untouched" "$(cat "$TMP/lntarget.txt" 2>/dev/null)"
  eq "a symlink destination receives the member itself" \
     "content" "$(cat "$TMP/lnout/mm.txt" 2>/dev/null)"
else
  echo "SKIP: symlink destination test (cannot create symlinks here)"
fi

# ---- a directory in the way fails that member only ----
# The one row of the README table that stops anything. It must stop exactly one
# member: earlier the read-only case aborted the whole extract, leaving every
# later member stale, which is the failure this guards against recurring.
# README 表格中唯一會中止東西的一列。它必須恰好只中止一個成員：先前唯讀那個情形
# 會中止整次解出，使其後所有成員停在舊內容，此檢查即為防止該失敗重演。
mkdir -p "$TMP/dirout/mm.txt"
rc=0; dirmsg=$("$ST" -x -f "$TMP/ro.tar" -C "$TMP/dirout" 2>&1) || rc=$?
[ "$rc" -ne 0 ] && ok "a directory in the way ends the run non-zero" \
                || bad "a directory in the way ends the run non-zero (got rc=0)"
# The message must name the cause, not an errno. Windows reports EACCES (13) here
# and POSIX EISDIR, and a reader given only the number goes to look at
# permissions. bsdtar says "Can't remove already-existing dir: Directory not
# empty" and GNU tar says "Cannot open: File exists"; ours was the least
# informative of the three until it named the directory outright.
# 訊息必須指出成因而非 errno。Windows 於此回報 EACCES（13）、POSIX 回報 EISDIR，只拿到
# 數字的讀者會跑去查權限。bsdtar 說 "Can't remove already-existing dir: Directory not
# empty"、GNU tar 說 "Cannot open: File exists"；在我們明白指出「那是個目錄」之前，
# 本工具的訊息是三者中最不具資訊量的。
case "$dirmsg" in
  *"a directory is already there"*) ok "the message says a directory is in the way" ;;
  *) bad "the message says a directory is in the way (got: $(printf '%s' "$dirmsg" | grep -i error | head -1 | cut -c1-70))" ;;
esac
eq "a member before the blocked one still extracts" \
   "content" "$(cat "$TMP/dirout/aa.txt" 2>/dev/null)"
eq "a member after the blocked one still extracts" \
   "content" "$(cat "$TMP/dirout/zz.txt" 2>/dev/null)"

# ---- a trailing slash on an operand does not break the ZIP backend ----
# `-c --zip -f out.zip src/` failed with libarchive's "Couldn't visit directory"
# and left a 22-byte empty ZIP behind, while `src` and `.` both worked. The tar
# codecs were unaffected, because TarWriter.archiveName strips the trailing
# slash before the walk -- only the ZIP backend saw the raw operand.
#
# It matters more than an odd operand form would suggest: the README's own ZIP
# examples are written WITH the trailing slash, so copying either line verbatim
# failed. Sixteen expert blind-test rounds never hit it, because they typed their
# own commands; a newcomer following the document hit it on the first run. The
# forms below are therefore the documented ones, not invented ones.
#
# The 22-byte leftover is the second half of the problem: `-t` reads it at exit 0
# with zero entries, so the README's own "confirm with -t" advice showed a clean
# empty archive rather than a failure.
#
# `-c --zip -f out.zip src/` 會以 libarchive 的 "Couldn't visit directory" 失敗，並留下
# 一個 22 位元組的空 ZIP，而 `src` 與 `.` 都正常。tar 各編碼器不受影響，因為
# TarWriter.archiveName 在走訪前就去掉了尾隨斜線——只有 ZIP 後端看得到原始運算元。
#
# 其重要性超過「一種奇怪的運算元寫法」：README 自己的 ZIP 範例就帶著尾隨斜線，因此照抄
# 任一行都會失敗。十六個熟練盲測回合從未碰到，因為它們打的是自己的指令；一個照著文件走
# 的新手第一輪就中。故下列形式取自文件本身，而非自行編造。
#
# 那個 22 位元組的殘骸是問題的另一半：`-t` 讀它會以 0 結束且零個項目，於是 README 自己
# 「用 -t 確認」的建議，顯示的是一個乾淨的空封存而不是一次失敗。
mkdir -p "$TMP/zipsrc/sub"
printf 'a\n' > "$TMP/zipsrc/a.txt"
printf 'b\n' > "$TMP/zipsrc/sub/b.txt"
# The suffix drives both the operand and its label. An earlier version built the
# label with `$([ ... ] && printf /)`, which under this file's `set -e` aborted
# the whole suite the moment the test was false: the substitution exited
# non-zero, so the assignment did, so the script stopped -- silently, with no
# summary line and no failure reported.
# 由後綴同時決定運算元與其標籤。先前的版本以 `$([ ... ] && printf /)` 組出標籤，在本檔
# 的 `set -e` 之下，只要該測試為假就會中止整個套件：替換回傳非 0，賦值即非 0，腳本便停
# 住——而且是靜默停住，沒有總結行，也沒有回報任何失敗。
for suffix in "" "/"; do
  form="$TMP/zipsrc$suffix"
  label="zipsrc$suffix"
  for codec in --zip --zip64; do
    rm -f "$TMP/z.zip"
    rc=0; "$ST" -c "$codec" -f "$TMP/z.zip" "$form" >/dev/null 2>&1 || rc=$?
    eq "$codec with operand '$label' succeeds" "0" "$rc"
    # Name the members rather than counting them: a ZIP listing includes the
    # directory entries too, so a count encodes an assumption about how many of
    # those there are. The first version asserted 3 and failed against a correct
    # archive holding 4.
    # 指名成員而不是數數：ZIP 的列表也包含目錄項目，故數量等於把「有幾個目錄項目」這個
    # 假設寫死。第一版斷言 3，結果在一份正確、含 4 個項目的封存上失敗。
    eq "$codec with operand '$label' stores the nested file" \
       "1" "$("$ST" -t -f "$TMP/z.zip" 2>/dev/null | grep -c 'sub/b.txt')"
    eq "$codec with operand '$label' stores the top-level file" \
       "1" "$("$ST" -t -f "$TMP/z.zip" 2>/dev/null | grep -c 'zipsrc/a.txt')"
  done
done

# ---- the archive does not end up inside itself ----
# `tar -cf backup.tar .` run inside the directory being backed up is a standing
# footgun: the output is created first, the walk then finds it, and a truncated
# snapshot of the archive is stored in the archive. Measured on one tree before
# the fix -- GNU tar refuses it ("archive cannot contain itself; not dumped"),
# while bsdtar and this tool both stored it. The embedded copy is useless and
# grows with the archive, so this follows the reference that guards.
# Identity is compared, not the path string, so a second check uses a different
# spelling of the same file to prove a path-equality shortcut would not pass.
#
# 在要備份的目錄內執行 `tar -cf backup.tar .` 是長年的陷阱：輸出先被建立，走訪隨後找到
# 它，於是封存的一份截斷快照被存進封存。修正前以同一棵樹實測——GNU tar 會拒絕
# （"archive cannot contain itself; not dumped"），而 bsdtar 與本工具都會存進去。內嵌的
# 副本無用且會隨封存變大，故此處跟隨會防守的那個參照實作。比對的是身分而非路徑字串，
# 因此第二項檢查以同一檔案的不同寫法驗證「只比字串」的作法無法通過。
SELF="$TMP/selfref"
mkdir -p "$SELF"
printf 'alpha\n' > "$SELF/a.txt"
printf 'beta\n'  > "$SELF/b.txt"
( cd "$SELF" && "$ST" -c -f backup.tar . >/dev/null 2>&1 )
eq "the archive is not stored inside itself" \
   "" "$("$ST" -t -f "$SELF/backup.tar" 2>/dev/null | grep 'backup.tar')"
eq "the other members are all still stored" \
   "3" "$("$ST" -t -f "$SELF/backup.tar" 2>/dev/null | wc -l | tr -d ' ')"

# The same file reached by a different spelling must still be recognised.
# 以不同寫法走到的同一個檔案，仍必須被辨識出來。
SELF2="$TMP/selfref2"
mkdir -p "$SELF2"
printf 'alpha\n' > "$SELF2/a.txt"
( cd "$SELF2" && "$ST" -c -f "./out/../backup2.tar" . >/dev/null 2>&1 || \
  "$ST" -c -f "$SELF2/backup2.tar" -C "$SELF2" . >/dev/null 2>&1 )
eq "a differently spelled path to the archive is still excluded" \
   "" "$("$ST" -t -f "$SELF2/backup2.tar" 2>/dev/null | grep 'backup2.tar')"

# Guard against over-triggering: an unrelated .tar inside the tree must still be
# archived. Excluding "the archive" must mean this archive, not any archive.
# 防止過度觸發：樹內不相關的 .tar 仍必須被收進去。排除「該封存」必須指這一個封存，
# 而非任何封存。
mkdir -p "$TMP/selfsrc"
printf 'alpha\n' > "$TMP/selfsrc/a.txt"
"$ST" -c -f "$TMP/selfsrc/unrelated.tar" -C "$SELF" a.txt >/dev/null 2>&1
"$ST" -c -f "$TMP/outside.tar" -C "$TMP/selfsrc" . >/dev/null 2>&1
eq "an unrelated tar inside the tree is still archived" \
   "1" "$("$ST" -t -f "$TMP/outside.tar" 2>/dev/null | grep -c 'unrelated.tar')"

# ---- a typeflag '6' entry from a raw fixture ----
# This runs on every platform, including Windows, which is the point: the
# platform that cannot create a FIFO is the one whose branch would otherwise
# never be executed by any test. The fixture is a raw ustar stream, so no
# mkfifo is needed to produce a FIFO *entry* -- only to produce a FIFO on disk.
# Either way the run must end 0 and the ordinary member beside it must land.
# 本段在每個平台上都會執行，Windows 亦然，而這正是重點：無法建立 FIFO 的那個平台，
# 正是其分支否則永遠不會被任何測試執行到的平台。此 fixture 是原始 ustar 位元流，
# 因此產生一個 FIFO **項目**不需要 mkfifo——只有在磁碟上產生 FIFO 才需要。無論
# 哪個平台，該次執行都必須以 0 結束，且其旁的一般成員必須落地。
if [ -f "$RAW" ]; then
  zsh "$RAW" "$TMP/rawfifo.tar" fifo pipe '' file beside.txt 'hello' 2>/dev/null
  mkdir -p "$TMP/rawout"
  out=$("$ST" -x -f "$TMP/rawfifo.tar" -C "$TMP/rawout" 2>&1); rc=$?
  eq "a typeflag '6' entry does not fail the run" "0" "$rc"
  eq "the member beside a FIFO entry still extracts" \
     "hello" "$(cat "$TMP/rawout/beside.txt" 2>/dev/null)"
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*)
      case "$out" in
        *"skipping FIFO"*) ok "Windows names the FIFO it skipped" ;;
        *) bad "Windows names the FIFO it skipped (got: $(printf '%s' "$out" | head -1))" ;;
      esac ;;
    *)
      [ -p "$TMP/rawout/pipe" ] && ok "a raw typeflag '6' entry becomes a FIFO" \
                               || bad "a raw typeflag '6' entry becomes a FIFO" ;;
  esac
else
  bad "raw typeflag '6' fixture (missing fixture generator $RAW)"
fi


# ---- a truncated .tar.gz is not an empty archive ----
# The short-input guard above catches a source that ends mid-header, but a
# .tar.gz cut inside its gzip header never reaches the tar layer at all: it
# decodes to zero bytes, and zero bytes is what a legal empty archive also
# looks like. gzipDecodeStream returned success for it, so `-t` printed nothing
# and exited 0 where bsdtar exits 1. The boundary was where the deflate data
# became long enough for inflate itself to object.
# 上方的短輸入守門擋得住「在標頭中途結束」的來源，但在 gzip 標頭內就被切斷的 .tar.gz
# 根本到不了 tar 層：它解出零位元組，而零位元組正是合法空封存的樣子。
# gzipDecodeStream 為其回報成功，於是 `-t` 不印任何內容並以 0 結束，而 bsdtar 為 1。
# 分界點落在 deflate 資料長到足以讓 inflate 自身提出異議之處。
TG="$TMP/truncgz"
mkdir -p "$TG/src"
printf 'alpha\n' > "$TG/src/a.txt"
"$ST" -c --gzip -f "$TG/full.tgz" -C "$TG" src >/dev/null 2>&1
full=$(wc -c < "$TG/full.tgz" | tr -d ' ')

# Every cut must be rejected. 10 bytes is the gzip header alone -- the case that
# used to pass -- and the largest cut still has to lose the trailing CRC.
# 每一種截斷都必須被拒絕。10 位元組僅為 gzip 標頭，正是先前會通過的案例；最大的截斷
# 也仍須缺少結尾的 CRC。
for cut in 10 20 30 50; do
  [ "$cut" -lt "$full" ] || continue
  head -c "$cut" "$TG/full.tgz" > "$TG/cut.tgz"
  if "$ST" -t -f "$TG/cut.tgz" >/dev/null 2>&1; then
    bad "a .tar.gz truncated to $cut bytes is rejected"
  else
    ok "a .tar.gz truncated to $cut bytes is rejected"
  fi
done

# The two shapes that must NOT be caught by that: an empty file is a legal empty
# archive, and an intact archive obviously still reads.
# 該檢查絕不能誤傷的兩種形狀：空檔案是合法的空封存，而完好的封存當然仍須讀得出來。
: > "$TG/empty"
"$ST" -t -f "$TG/empty" >/dev/null 2>&1 \
  && ok "an empty file is still a legal empty archive" \
  || bad "an empty file is still a legal empty archive"
eq "an intact .tar.gz still lists its members" "2" \
   "$("$ST" -t -f "$TG/full.tgz" 2>/dev/null | wc -l | tr -d ' ')"

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
