#!/usr/bin/env zsh
# test_00_tools.zsh -- the external tools the rest of test/ relies on actually work in this zsh.
# test_00_tools.zsh -- test/ 其他測試依賴的外部工具，在這個 zsh 裡真的能用。
#
#   ./test/test_00_tools.zsh          # check every tool; exit 1 if any is broken
#   ./test/test_00_tools.zsh --help   # this synopsis
#
# Each tool is run on a known input and its output compared with the known answer -- an exit
# status alone is not trusted. On 2026-10-19 a zsh port launched through scoop's `current`
# junction made every external command found on PATH exit 127 with no output and no message
# (uname, tail, head, sort, ls, cat...). Nothing failed loudly: `case "$(uname -s)"` saw an
# empty string, so the suites picked the non-Windows binary and switched off their Windows
# guards, then reported on the wrong premise. This file's name sorts first so it runs before
# them, and a failure prints where the name resolved (`whence -p`). The platform comes from
# zsh's own $OSTYPE, so uname is checked rather than assumed. Composite checks are shell
# functions, not nested `zsh -c`, which through the scoop shim mangles positional arguments.
# Tools a platform may lack (timeout, shasum/sha256sum) SKIP when absent; present but broken
# is a FAIL.
#
# 每個工具都用已知輸入執行，輸出與已知答案比對——不相信單一退出碼。2026-10-19 某版 zsh port
# 經 scoop 的 `current` junction 啟動時，經 PATH 找到的每個外部指令都以 127 結束，沒有輸出也沒有
# 訊息（uname、tail、head、sort、ls、cat……）。沒有任何東西大聲失敗：`case "$(uname -s)"` 看到
# 空字串，於是測試挑了非 Windows 的執行檔、關掉 Windows 守門，然後在錯的前提上繼續回報。本檔名
# 排在最前面，所以先於它們執行；失敗時印出該名稱解析到哪裡（`whence -p`）。平台取自 zsh 自己的
# $OSTYPE，所以 uname 是被檢查而非被假定。組合檢查寫成 shell 函式，而非巢狀 `zsh -c`——經 scoop
# shim 時後者會弄壞位置參數。某些平台可能沒有的工具（timeout、shasum／sha256sum）不存在時
# SKIP；存在卻壞了就是 FAIL。
set -u

script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  # Builtins only: --help must answer even when the tools under test are the broken ones.
  # 只用內建指令：受測的工具壞掉時，--help 也必須能回答。
  for l in "${(@f)$(<"$script_path")}"; do
    [[ $l == '#!'* ]] && continue
    [[ $l == '#'* ]] || break
    l=${l#\#}; printf '%s\n' "${l# }"
  done
  exit 0
fi

pass=0; fail=0
ok()    { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)) }
bad()   { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)) }
where() { local p; p=$(whence -p "$1"); printf '%s' "${p:-<not found>}" }

# check <tool> <expected output> <command...>
# Requires status 0 and exactly the expected output (stdout and stderr together).
# 要求退出碼 0，且輸出（stdout 與 stderr 合併）完全相符。
check() {
  local tool=$1 want=$2; shift 2
  local got rc=0
  got=$("$@" 2>&1) || rc=$?
  if (( rc == 0 )) && [[ $got == $want ]]; then
    ok "$tool"
  else
    bad "$tool (rc $rc, want '${want//$'\n'/\\n}', got '${got//$'\n'/\\n}'; resolves to $(where $tool))"
  fi
}
# optional <tool> ... -- as check, but SKIP when the tool is not on PATH at all.
# 同 check，但工具完全不在 PATH 上時 SKIP。
optional() {
  if [[ -z $(whence -p "$1") ]]; then printf 'SKIP: %s (not on PATH)\n' "$1"; return; fi
  check "$@"
}

TMP=$(mktemp -d) || TMP=""
if [[ -n $TMP && -d $TMP ]]; then
  ok "mktemp -d"
  trap 'rm -rf -- "$TMP"' EXIT
else
  bad "mktemp -d (got '$TMP'; resolves to $(where mktemp))"
  # Carry on in a directory made by zsh's own builtins, so one broken tool does not hide the
  # rest: with the 2026-10-19 port, mktemp was simply the first of many to fail.
  # 改用 zsh 內建指令建立的目錄繼續，免得一個工具壞掉就遮住其餘：2026-10-19 那版 port 下，
  # mktemp 只是第一個失敗的。
  zmodload -F zsh/files b:zf_mkdir b:zf_rm
  TMP="${TMPDIR:-/tmp}/test_00_tools.$$"
  zf_mkdir -p -- "$TMP" || { printf 'FAIL: cannot create %s either\n' "$TMP"; exit 1 }
  trap 'zf_rm -rf -- "$TMP"' EXIT
fi
# The directory must be writable by zsh itself: an earlier port listed /tmp but could not
# create files in it. / 這個目錄必須能由 zsh 自己寫入：更早某版 port 能列出 /tmp 卻無法在其中建檔。
if print -r -- probe > "$TMP/probe" && [[ $(<"$TMP/probe") == probe ]]; then
  ok "mktemp -d gives a directory zsh can write"
else
  bad "mktemp -d gives a directory zsh can write ($TMP)"
fi
mkdir "$TMP/one" && print -r -- x > "$TMP/one/only"
printf 'a\nb\nc\n' > "$TMP/abc"
printf 'c\na\nb\n' > "$TMP/cab"
printf 'A' > "$TMP/A"
printf 'abc' > "$TMP/hashme"
print -r -- p1 > "$TMP/p1"; print -r -- p2 > "$TMP/p2"

# ---- platform name / 平台名稱 ----
case $OSTYPE in
  msys*|cygwin*|mingw*) uname_pat='(MSYS|MINGW|CYGWIN)*' ;;   # this port reports mingw32
  linux*)        uname_pat='Linux' ;;
  darwin*)       uname_pat='Darwin' ;;
  *)             uname_pat='?*' ;;
esac
rc=0; got=$(uname -s 2>&1) || rc=$?
if (( rc == 0 )) && [[ $got == ${~uname_pat} ]]; then ok "uname -s ($got)"
else bad "uname -s (rc $rc, got '$got', want $uname_pat for OSTYPE=$OSTYPE; resolves to $(where uname))"; fi

# ---- composite checks as functions / 以函式寫的組合檢查 ----
t_wc()    { local n; n=$(wc -l < "$TMP/abc") && print -r -- ${n// /} }
t_tee()   { print -r -- t | tee "$TMP/tee.out" >/dev/null && print -r -- "$(<"$TMP/tee.out")" }
t_date()  { local y; y=$(date +%Y) && [[ $y == <1970-9999> ]] && print ok }
t_cmp()   { cmp -s "$TMP/abc" "$TMP/abc" && ! cmp -s "$TMP/abc" "$TMP/cab" && print ok }
t_find()  { local f; f=$(find "$TMP/one" -name only) && print -r -- ${f:t} }
t_cp()    { cp "$TMP/abc" "$TMP/cp" && print -r -- "$(<"$TMP/cp")" }
t_mv()    { cp "$TMP/abc" "$TMP/m1" && mv "$TMP/m1" "$TMP/m2" && [[ ! -e $TMP/m1 && -e $TMP/m2 ]] && print ok }
t_mkdir() { mkdir -p "$TMP/d/e" && [[ -d $TMP/d/e ]] && print ok }
t_rm()    { cp "$TMP/abc" "$TMP/r" && rm -f "$TMP/r" && [[ ! -e $TMP/r ]] && print ok }
t_chmod() { chmod 644 "$TMP/abc" && print ok }
t_touch() { touch -t 202001020304.05 "$TMP/t" && [[ -e $TMP/t ]] && print ok }
t_stat()  { stat "$TMP/abc" >/dev/null && print ok }
# dd's record counts go to stderr by design on every platform; they are not a diagnostic here.
# dd 的記錄數在各平台本來就印在 stderr；在此不是診斷訊息。
t_dd()    { local n; n=$(dd if=/dev/zero bs=1 count=3 2>/dev/null | wc -c) && print -r -- ${n// /} }
t_sleep() { sleep 0 && print ok }
t_id()    { local u; u=$(id -u) && [[ $u == <-> ]] && print ok }
t_od()    { local h; h=$(od -An -tx1 "$TMP/A") && print -r -- ${h// /} }
t_timeout()   { timeout 5 true && print ok }
t_sha256sum() { local h; h=$(sha256sum "$TMP/hashme") && print -r -- ${h%% *} }
t_shasum()    { local h; h=$(shasum -a 256 "$TMP/hashme") && print -r -- ${h%% *} }

# ---- text tools / 文字工具 ----
check head     a          head -1 "$TMP/abc"
check tail     c          tail -1 "$TMP/abc"
check sort     $'a\nb\nc' sort "$TMP/cab"
check cat      $'a\nb\nc' cat "$TMP/abc"
check grep     1          grep -c b "$TMP/abc"
check sed      z          sed -n 's/a/z/p' "$TMP/abc"
check awk      two        awk '{print $2}' <<< 'one two three'
check tr       ABC        tr a-z A-Z <<< abc
check cut      y          cut -d, -f2 <<< 'x,y,z'
check wc       3          t_wc
check od       41         t_od
check paste    'p1,p2'    paste -d, "$TMP/p1" "$TMP/p2"
check xargs    'x y'      xargs printf '%s %s\n' <<< 'x y'
check tee      t          t_tee
check basename abc        basename "$TMP/abc"
check dirname  "$TMP"     dirname "$TMP/abc"
check date     ok         t_date

# ---- files / 檔案 ----
check cmp      ok         t_cmp
check diff     ''         diff "$TMP/abc" "$TMP/abc"
check ls       only       ls "$TMP/one"
check find     only       t_find
check cp       $'a\nb\nc' t_cp
check mv       ok         t_mv
check mkdir    ok         t_mkdir
check rm       ok         t_rm
check chmod    ok         t_chmod
check touch    ok         t_touch
check stat     ok         t_stat
check dd       3          t_dd
check sleep    ok         t_sleep
check id       ok         t_id

# ---- may be absent / 可能不存在 ----
want_sha=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
optional timeout   ok        t_timeout
optional sha256sum $want_sha t_sha256sum
optional shasum    $want_sha t_shasum

printf -- '-----------------------------------------\nPASS: %s  FAIL: %s\n' "$pass" "$fail"
(( fail == 0 ))
