#!/usr/bin/env zsh
# test/test_junction_extract.zsh -- -x never writes through a junction already under -C (Windows).
# test/test_junction_extract.zsh -- -x 絕不穿過 -C 之下既有的 junction 寫出（Windows）。
#
#   ./test/test_junction_extract.zsh          run against release/swift_tar.exe / 以 release/swift_tar.exe 執行
#   ./test/test_junction_extract.zsh --help   print this synopsis and exit / 印出本說明後結束
#
# A junction (IO_REPARSE_TAG_MOUNT_POINT) reports as a plain directory to FileManager, so the
# "path passes through a symlink" check let it through: with `dest/j` a junction to a directory
# outside, a member `j/evil.txt` was written outside -C and -x exited 0, on tar and ZIP alike, and
# --no-links could not help because the junction was on disk before the run (2026-10-24 review).
# A `mklink /D` symlink in the same place was refused; it is kept here as the control, beside a
# plain directory `j`, which must still be extracted into -- a check that refused everything
# would pass the junction cases too.
# junction（IO_REPARSE_TAG_MOUNT_POINT）在 FileManager 看來是一般目錄，於是「路徑穿過 symlink」
# 的檢查放行了它：`dest/j` 是指向外部目錄的 junction 時，成員 `j/evil.txt` 被寫到 -C 之外且 -x
# 以 0 結束，tar 與 ZIP 皆然；--no-links 也擋不住，因為 junction 在執行前就已在磁碟上（2026-10-24
# 審查）。同位置的 `mklink /D` symlink 會被拒絕，此處保留為對照組；另有一般目錄 `j` 必須照常解入
# ——一個什麼都拒絕的檢查也會通過 junction 案例。
set -euo pipefail

script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,6p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*) ;;
  *) print -r -- "SKIP: junctions exist only on Windows / junction 只存在於 Windows"
     print -r -- "PASS: 0  FAIL: 0  SKIP: 1"; exit 0 ;;
esac

ROOT="${script_path:h:h}"
ST="${ST:-$ROOT/release/swift_tar.exe}"
[[ -x $ST ]] || { print -u2 "error: build first -- missing $ST / 請先建置"; exit 1 }
RAW="$ROOT/verifications/make_raw_tar.zsh"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

pass=0 fail=0 skip=0
ok()   { print -r -- "PASS: $1"; pass=$((pass + 1)) }
bad()  { print -r -- "FAIL: $1"; fail=$((fail + 1)) }
skipc(){ print -r -- "SKIP: $1"; skip=$((skip + 1)) }

# Fixtures: the same two members as a tar and as a ZIP, plus a tar whose hard link targets a file
# through `j`. outside/secret.txt is what that hard link would reach.
# 測資：同樣兩個成員各做成 tar 與 ZIP，另有一個 tar 的硬連結目標經由 `j`。outside/secret.txt 是
# 該硬連結會碰到的檔案。
zsh "$RAW" "$TMP/j.tar" file j/evil.txt pwned file ok.txt fine >/dev/null
zsh "$RAW" "$TMP/h.tar" hard h.txt j/secret.txt file ok.txt fine >/dev/null
mkdir -p "$TMP/zsrc/j"
print -n pwned > "$TMP/zsrc/j/evil.txt"
print -n fine > "$TMP/zsrc/ok.txt"
( cd "$TMP/zsrc" && "$ST" -c --zip -f "$TMP/j.zip" j/evil.txt ok.txt )
# Two more ZIPs for the bridge's walk (2026-10-30 review, finding A). long.zip names
# `j/<5 x 240 a>/evil.txt`, 1217 characters: the walk returned "not blocked" for any name past its
# 1040-character buffer, and that member was written outside with exit 0. dot.zip names
# `./j/evil.txt`, so the `\\?\` lookup that fixed it must still skip `.` the way libarchive does.
# Windows' own bsdtar builds long.zip from an mtree spec; relative names, as everywhere here.
# 另兩個 ZIP 給橋接層的走訪（2026-10-30 審查，發現 A）。long.zip 的成員是 `j/<5 x 240 個 a>/evil.txt`，
# 1217 字元：走訪對超過 1040 字元緩衝區的名稱一律回傳「沒擋住」，該成員被寫到外部並以 0 結束。
# dot.zip 的成員是 `./j/evil.txt`，修好它的 `\\?\` 查詢仍須像 libarchive 一樣略過 `.`。long.zip 以
# Windows 內建的 bsdtar 從 mtree 規格建立；與本檔其他地方一樣只用相對名稱。
seg=$(printf 'a%.0s' {1..240})
{ printf '#mtree\n'
  printf './j/%s/%s/%s/%s/%s/evil.txt type=file contents=j/evil.txt\n' $seg $seg $seg $seg $seg
  printf './ok.txt type=file contents=ok.txt\n'
} > "$TMP/zsrc/long.mtree"
( cd "$TMP/zsrc" && /c/Windows/System32/tar.exe --format zip -cf ../long.zip @long.mtree ) </dev/null
( cd "$TMP/zsrc" && "$ST" -c --zip -f "$TMP/dot.zip" ./j/evil.txt ok.txt ) </dev/null
# A lone directory entry `j/` dated 1970-01-02 (2026-10-30 review, finding B). The ZIP path let
# libarchive set that time THROUGH a junction `j`, on the outside directory, exit 0; tar did not.
# 單獨的目錄項目 `j/`，日期 1970-01-02（2026-10-30 審查，發現 B）。ZIP 路徑讓 libarchive **穿過**
# junction `j` 把該時間設到外部目錄上並以 0 結束；tar 不會。
mkdir -p "$TMP/dsrc/j"
touch -d @86400 "$TMP/dsrc/j"
( cd "$TMP/dsrc" && "$ST" -c --zip -f "$TMP/dj.zip" j && "$ST" -c -f "$TMP/dj.tar" j ) </dev/null
zmodload -F zsh/stat b:zstat

# Make dest/ with `j` as <kind>: J = junction, D = directory symlink, plain = ordinary directory.
# Relative paths with the inherited cwd, never cygpath-built ones (see test_dereference.zsh).
# 建立 dest/，其中 `j` 為 <kind>：J = junction、D = 目錄 symlink、plain = 一般目錄。路徑用相對
# 路徑並繼承 cwd，絕不用 cygpath 組（見 test_dereference.zsh）。
fresh() {
  rm -rf -- "$TMP/dest" "$TMP/outside"
  mkdir -p "$TMP/dest" "$TMP/outside"
  print -n secret > "$TMP/outside/secret.txt"
  case $1 in
    plain) mkdir "$TMP/dest/j" ;;
    *) ( cd "$TMP/dest" && cmd.exe //c mklink //$1 j '..\outside' ) >/dev/null 2>&1 </dev/null \
         || return 1 ;;
  esac
  return 0
}

# run <archive> [options...] -- extract into dest/, leave rc and stderr in $rc / $TMP/err.
# run <封存> [選項...]——解到 dest/，rc 與 stderr 留在 $rc 與 $TMP/err。
run() {
  local archive=$1; shift
  rc=0; "$ST" -x "$@" -f "$archive" -C "$TMP/dest" 2>"$TMP/err" </dev/null || rc=$?
}

# must_refuse <label> -- the member through `j` is refused, counted, and nothing lands outside.
# must_refuse <標籤>——經由 `j` 的成員被拒絕、被計入，且外部沒有任何東西落地。
must_refuse() {
  (( rc != 0 )) && ok "$1: exits non-zero under default --strict / 預設嚴格下以非零結束" \
                || { bad "$1: exit 0"; cat "$TMP/err" }
  [[ ! -e $TMP/outside/evil.txt ]] && ok "$1: nothing written outside -C / -C 之外沒有寫出任何東西" \
                                   || bad "$1: outside/evil.txt written ($(cat "$TMP/outside/evil.txt"))"
  [[ $(cat "$TMP/dest/ok.txt" 2>/dev/null) == fine ]] && ok "$1: the safe member is still extracted / 安全成員仍解出" \
                                                       || bad "$1: ok.txt missing"
}

for kind in J D; do
  name=$([[ $kind == J ]] && print junction || print 'symlink (control) / 對照組')
  if ! fresh $kind; then
    skipc "mklink /$kind failed (Developer Mode or admin needed) / mklink /$kind 失敗（需開發者模式或管理員）"
    continue
  fi
  run "$TMP/j.tar";             must_refuse "tar via $name"
  fresh $kind; run "$TMP/j.tar" --no-links; must_refuse "tar --no-links via $name"
  fresh $kind; run "$TMP/j.zip";             must_refuse "zip via $name"
  fresh $kind; run "$TMP/j.zip" --no-links; must_refuse "zip --no-links via $name"
  fresh $kind; run "$TMP/long.zip"
  # evil.txt sits five directories down here, so look for it anywhere outside.
  # 此處 evil.txt 在五層目錄之下，所以在外部的任何位置找它。
  outside_hits=( "$TMP"/outside/**/evil.txt(N) )
  (( rc != 0 && ${#outside_hits} == 0 )) \
    && ok "zip 1217-char name via $name: refused, nothing outside / 1217 字元名稱被拒絕、外部無檔案" \
    || { bad "zip 1217-char name via $name: rc=$rc, files outside=${#outside_hits}"; cat "$TMP/err" }
  fresh $kind; run "$TMP/dot.zip";           must_refuse "zip ./j/ via $name"
  for archive in dj.zip dj.tar; do
    fresh $kind; touch -d @1000000000 "$TMP/outside"; run "$TMP/$archive"
    got=$(zstat +mtime -- "$TMP/outside")
    (( rc == 0 && got == 1000000000 )) \
      && ok "${archive:e} entry j/ over $name: outside mtime untouched / 外部 mtime 未被改動" \
      || { bad "${archive:e} entry j/ over $name: rc=$rc, outside mtime=$got (want 1000000000)"; cat "$TMP/err" }
  done
  fresh $kind; run "$TMP/h.tar"
  (( rc != 0 )) && [[ ! -e $TMP/dest/h.txt ]] \
    && ok "tar hard link via $name: refused, not created / 硬連結被拒絕、未建立" \
    || { bad "tar hard link via $name: rc=$rc, h.txt exists=$([[ -e $TMP/dest/h.txt ]] && print yes || print no)"; cat "$TMP/err" }
done

# Allow side: an ordinary directory `j` is extracted into, on both backends.
# 放行側：一般目錄 `j` 照常解入，兩個後端皆然。
for archive in j.tar j.zip; do
  fresh plain; run "$TMP/$archive"
  (( rc == 0 )) && [[ $(cat "$TMP/dest/j/evil.txt") == pwned ]] \
    && ok "${archive:e}: a plain directory j is extracted into / 一般目錄 j 照常解入" \
    || { bad "${archive:e}: plain directory: rc=$rc"; cat "$TMP/err" }
done
# The long name is extracted under a plain `j`: refusing every name past MAX_PATH would pass the
# junction case above too.
# 一般目錄 `j` 之下，長名稱照常解出：把超過 MAX_PATH 的名稱一律拒絕，也會通過上面的 junction 案例。
fresh plain; run "$TMP/long.zip"
inside_hits=( "$TMP"/dest/j/**/evil.txt(N) )
(( rc == 0 && ${#inside_hits} == 1 )) \
  && ok "zip: a 1217-char name under a plain directory j is extracted / 一般目錄 j 下的 1217 字元名稱照常解出" \
  || { bad "zip: 1217-char name under a plain j: rc=$rc, found=${#inside_hits}"; cat "$TMP/err" }
for archive in dj.zip dj.tar; do
  fresh plain; run "$TMP/$archive"
  got=$(zstat +mtime -- "$TMP/dest/j")
  (( rc == 0 && got == 86400 )) \
    && ok "${archive:e}: entry j/ over a plain directory j sets its mtime / 一般目錄 j 的 mtime 照常設定" \
    || { bad "${archive:e}: entry j/ over a plain j: rc=$rc, mtime=$got (want 86400)"; cat "$TMP/err" }
done
fresh plain; run "$TMP/dot.zip"
(( rc == 0 )) && [[ $(cat "$TMP/dest/j/evil.txt") == pwned ]] \
  && ok "zip: ./j/evil.txt under a plain directory j is extracted / 一般目錄 j 下的 ./j/evil.txt 照常解出" \
  || { bad "zip: ./j/ under a plain j: rc=$rc"; cat "$TMP/err" }

print -r -- "PASS: $pass  FAIL: $fail  SKIP: $skip"
(( fail == 0 ))
