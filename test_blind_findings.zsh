#!/usr/bin/env zsh
# test_blind_findings.zsh -- regression tests for the defects found by the
# read_easy blind documentation test (rounds 1-16, 2026-08-18).
# test_blind_findings.zsh -- read_easy 盲測（2026-08-18，round 1-16）所發現
# 缺陷的回歸測試。
#
#   ./test_blind_findings.zsh          # run against release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test_blind_findings.zsh   # or a specific binary
#   ./test_blind_findings.zsh --help
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
if [ -z "${ST:-}" ]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$HERE/release/swift_tar.exe" ;;
    *) ST="$HERE/release/swift_tar" ;;
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
  "$z_producer" -a -cf "$TMP/z.tar.Z" -C "$ZS" . >/dev/null 2>&1

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
  ( cd "$DEV/src" && "$SYS_TAR" -cf "$TMP/dev.tar" . ) >/dev/null 2>&1
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
RAW="${0:A:h}/verifications/make_raw_tar.zsh"
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
else
  echo "SKIP: path traversal (verifications/make_raw_tar.zsh missing)"
fi

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
