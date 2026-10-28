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

print -r -- "PASS: $pass  FAIL: $fail  SKIP: $skip"
(( fail == 0 ))
