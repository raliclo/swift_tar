#!/usr/bin/env zsh
# test/test_no_links.zsh -- verify that -x --no-links creates no symlink or hard link member.
# test/test_no_links.zsh -- 驗證 -x --no-links 不建立任何符號連結或硬連結成員。
#
#   ./test/test_no_links.zsh          run against release/swift_tar / 以 release/swift_tar 執行
#   ./test/test_no_links.zsh --help   print this synopsis and exit / 印出本說明後結束
#
# Requested 2026-10-23 by LiveFiles, which extracts untrusted uploads: without the option
# -x creates `portal -> ../..` and exits 0. The stderr line is a contract the caller greps,
# so it is compared whole.
# 2026-10-23 由 LiveFiles 提出，它要解開不可信的上傳：不加此選項時，-x 會建立
# `portal -> ../..` 並以 0 結束。stderr 那一行是呼叫端會去比對的約定，所以整行比對。
set -euo pipefail

script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,12p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

ROOT="${script_path:h:h}"
if [[ -z ${ST:-} ]]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$ROOT/release/swift_tar.exe" ;;
    *) ST="$ROOT/release/swift_tar" ;;
  esac
fi
[[ -x $ST ]] || { print -u2 "error: build first -- missing $ST / 請先建置"; exit 1 }
RAW="$ROOT/verifications/make_raw_tar.zsh"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

pass=0 fail=0 skip=0
ok()   { print -r -- "PASS: $1"; pass=$((pass + 1)) }
bad()  { print -r -- "FAIL: $1"; fail=$((fail + 1)) }
skipc(){ print -r -- "SKIP: $1"; skip=$((skip + 1)) }
has_line() { grep -Fxq -- "$2" "$1" }

SYM="swift_tar: skipping link 'portal' (symlink -> ../..) / 略過連結 'portal'（符號連結 -> ../..）"
HARD="swift_tar: skipping link 'b.txt' (hardlink -> a.txt) / 略過連結 'b.txt'（硬連結 -> a.txt）"

# Fixture: a file, an outward symlink, a hard link to the file, another file.
# 測資：一個檔案、一個向外的 symlink、一個指向該檔案的硬連結、再一個檔案。
zsh "$RAW" "$TMP/l.tar" file a.txt hello link portal ../.. hard b.txt a.txt file c.txt world

# 1. Baseline: without --no-links the outward symlink is created (this is the gap).
#    基準：不加 --no-links 時會建立向外的 symlink（這正是缺口）。
mkdir "$TMP/o0"
rc=0; "$ST" -x -f "$TMP/l.tar" -C "$TMP/o0" 2>"$TMP/e0" || rc=$?
if (( rc == 0 )) && { [[ -L $TMP/o0/portal ]] || [[ -e $TMP/o0/portal ]] }; then
  ok "without --no-links the link is created, exit 0 / 不加時會建立連結"
elif [[ $(uname -s) == (MSYS|MINGW|CYGWIN)* ]]; then
  skipc "baseline symlink creation needs symlink rights on Windows / Windows 建立 symlink 需權限"
else
  bad "baseline: rc=$rc, portal missing / 基準：rc=$rc，沒有 portal"
fi

# 2. --no-links on plain tar: files land, links do not, exit 0, one exact line per link.
#    純 tar 加 --no-links：檔案落地、連結不建立、以 0 結束、每個連結一行精確訊息。
check_tar() {
  local label=$1 archive=$2 out=$TMP/o-$1
  mkdir "$out"
  local rc=0
  "$ST" -x --no-links -f "$archive" -C "$out" 2>"$TMP/e-$label" || rc=$?
  (( rc == 0 )) && ok "$label: exit 0 under default --strict / 預設嚴格下仍以 0 結束" \
                || { bad "$label: exit $rc / 結束碼 $rc"; cat "$TMP/e-$label" }
  [[ $(cat "$out/a.txt") == hello && $(cat "$out/c.txt") == world ]] \
    && ok "$label: regular members extracted / 一般成員已解出" || bad "$label: regular members missing / 缺一般成員"
  [[ ! -e $out/portal && ! -L $out/portal ]] && ok "$label: no symlink created / 未建立 symlink" \
                                            || bad "$label: portal exists / portal 存在"
  [[ ! -e $out/b.txt ]] && ok "$label: no hard link created / 未建立硬連結" || bad "$label: b.txt exists / b.txt 存在"
  has_line "$TMP/e-$label" "$SYM"  && ok "$label: symlink line / symlink 訊息" || { bad "$label: symlink line missing"; cat "$TMP/e-$label" }
  has_line "$TMP/e-$label" "$HARD" && ok "$label: hardlink line / 硬連結訊息" || { bad "$label: hardlink line missing"; cat "$TMP/e-$label" }
  [[ $(grep -c 'skipping link' "$TMP/e-$label") == 2 ]] && ok "$label: exactly two link lines / 恰好兩行" \
                                                        || bad "$label: link line count / 行數不對"
}
check_tar tar "$TMP/l.tar"

# 3. The same through a compressed stream, the form LiveFiles receives (.tar.zst).
#    經壓縮串流再測一次，即 LiveFiles 收到的形式（.tar.zst）。
if command -v zstd >/dev/null 2>&1; then
  zstd -q -c "$TMP/l.tar" > "$TMP/l.tar.zst"
  check_tar zst "$TMP/l.tar.zst"
else
  skipc "zstd CLI not on PATH; .tar.zst case not run / PATH 上沒有 zstd"
fi

# 4. A link with an unsafe name is still refused as unsafe and still counts for --strict.
#    名稱不安全的連結仍以不安全路徑拒絕，並計入 --strict。
zsh "$RAW" "$TMP/u.tar" link ../evil x file ok.txt fine
mkdir "$TMP/ou"
rc=0; "$ST" -x --no-links -f "$TMP/u.tar" -C "$TMP/ou" 2>"$TMP/eu" || rc=$?
(( rc != 0 )) && ok "unsafe link name still fails --strict / 不安全名稱仍使嚴格模式失敗" || bad "unsafe link: exit 0"
grep -q "skipping unsafe path '../evil'" "$TMP/eu" && ok "unsafe link reported as unsafe / 以不安全路徑回報" \
                                                    || { bad "unsafe line missing"; cat "$TMP/eu" }
! grep -q 'skipping link' "$TMP/eu" && ok "unsafe link not reported as a --no-links drop / 不以 --no-links 回報" \
                                     || bad "unsafe link also reported as link"
rc=0; "$ST" -x --no-links --no-strict -f "$TMP/u.tar" -C "$TMP/ou" 2>/dev/null || rc=$?
(( rc == 0 )) && ok "--no-strict still exits 0 / --no-strict 仍以 0 結束" || bad "--no-strict exit $rc"

# 5. -t is unaffected: links are still listed.
#    -t 不受影響：連結仍會列出。
"$ST" -t --no-links -f "$TMP/l.tar" > "$TMP/list" 2>"$TMP/el"
grep -qx portal "$TMP/list" && grep -qx b.txt "$TMP/list" && ok "-t still lists links / -t 仍列出連結" \
                                                         || { bad "-t listing changed"; cat "$TMP/list" }

# 6. -O writes nothing to disk, so --no-links has nothing to report.
#    -O 不寫磁碟，所以 --no-links 沒有可回報的東西。
rc=0; "$ST" -x -O --no-links -f "$TMP/l.tar" > "$TMP/stdout" 2>"$TMP/eO" || rc=$?
(( rc == 0 )) && ! grep -q 'skipping link' "$TMP/eO" && [[ $(cat "$TMP/stdout") == helloworld ]] \
  && ok "-O: contents only, no link lines / -O 只輸出內容、不報連結" || bad "-O: rc=$rc or unexpected output"

# 7. ZIP: the C backend applies the same rule and prints the same line. The fixture needs a
#    real symlink on disk; MSYS `ln -s` copies instead, so it is checked with -L.
#    ZIP：C 後端套用同一規則、印同一行。測資需要磁碟上真正的 symlink；MSYS 的 `ln -s` 會改成
#    複製，所以先以 -L 確認。
mkdir -p "$TMP/zsrc"
print -n hello > "$TMP/zsrc/a.txt"
ln -s ../.. "$TMP/zsrc/portal" 2>/dev/null || true
if [[ -L $TMP/zsrc/portal ]]; then
  ( cd "$TMP/zsrc" && "$ST" -c --zip -f "$TMP/l.zip" a.txt portal )
  mkdir "$TMP/oz"
  rc=0; "$ST" -x --no-links -f "$TMP/l.zip" -C "$TMP/oz" 2>"$TMP/ez" || rc=$?
  (( rc == 0 )) && ok "zip: exit 0 / zip：以 0 結束" || { bad "zip: exit $rc"; cat "$TMP/ez" }
  [[ $(cat "$TMP/oz/a.txt") == hello ]] && ok "zip: file extracted / zip：檔案已解出" || bad "zip: a.txt missing"
  [[ ! -e $TMP/oz/portal && ! -L $TMP/oz/portal ]] && ok "zip: no symlink created / zip：未建立 symlink" \
                                                  || bad "zip: portal exists"
  has_line "$TMP/ez" "$SYM" && ok "zip: same line as tar / zip：訊息與 tar 相同" || { bad "zip: line missing"; cat "$TMP/ez" }
else
  skipc "zip: cannot make a real symlink here / 此處無法建立真正的 symlink"
fi

print -r -- "PASS: $pass  FAIL: $fail  SKIP: $skip"
(( fail == 0 ))
