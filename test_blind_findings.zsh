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

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
