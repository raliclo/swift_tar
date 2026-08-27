#!/usr/bin/env zsh
set -uo pipefail

# `-p` / `--same-permissions` / `--no-same-permissions` on extract.
#
# Until 2026-08-20 extraction always restored the archive's mode verbatim, with
# no way to ask for anything else -- the equivalent of GNU tar with `-p` always
# on. That is a reasonable default but it was not a choice anyone could make, and
# a caller wanting GNU's non-root behaviour had no spelling for it.
#
# The default is deliberately unchanged. Flipping it would alter every caller
# that works today, silently, and the symptom would be permissions rather than an
# error.
#
# 解壓時的 `-p`／`--same-permissions`／`--no-same-permissions`。
#
# 在 2026-08-20 之前，解壓一律原樣還原封存中的 mode，且無從要求其他行為——等同 GNU tar
# 恆常帶著 `-p`。那是個合理的預設，但它不是任何人做得了的選擇；想要 GNU 非 root 行為的
# 呼叫端根本沒有對應的寫法。
#
# 預設刻意維持不變。翻轉它會無聲改變今天所有可運作的呼叫端，而症狀會是權限而非錯誤。
#
# 測試用一個 0666 的成員，而不是常見的 0644：umask 022 對 0644 沒有可見效果，那樣的測試
# 無論實作對錯都會通過。
# The fixture is 0666 rather than the more usual 0644: a umask of 022 has no
# visible effect on 0644, so that test would pass whether the code worked or not.

script_dir=${0:A:h}
root=${script_dir:h}
cd "$root"

tar=release/swift_tar
[[ $(uname -s) == *NT* ]] && tar=release/swift_tar.exe
[[ -x $tar ]] || { print -u2 -- "找不到 $tar；請先建置 / missing $tar"; exit 1 }

if [[ $(uname -s) == *NT* ]]; then
  print -- "略過：Windows 沒有 POSIX mode bits / skipped: no POSIX mode bits on Windows"
  exit 0
fi

failures=0
check() {
  if [[ $1 == $2 ]]; then
    print -- "  ok   $3"
  else
    print -- "  FAIL $3 (expected $1, got $2)"
    (( failures += 1 ))
  fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar_abs=$root/$tar

# umask 固定為 022 而非沿用呼叫者的：這個測試斷言的是「umask 有被套用」，若沿用環境值，
# 在 umask 000 的機器上它會與「完全沒套用」無從分辨。
# Fix the umask at 022 rather than inheriting the caller's: this asserts that the
# umask is applied, and inheriting would make it indistinguishable from "not
# applied at all" on a machine with umask 000.
umask 022

mkdir -p "$work/src"
printf x > "$work/src/wide.txt";  chmod 0666 "$work/src/wide.txt"
printf x > "$work/src/exec.sh";   chmod 0777 "$work/src/exec.sh"
( cd "$work" && "$tar_abs" -c --zstd -f a.tzst src ) 2>/dev/null

# 權限位元由 zsh 自己的 zsh/stat 模組讀取，不呼叫外部 stat。
#
# 外部 stat 在這三種環境各有一種壞法，而且壞得都很安靜：BSD（macOS）用
# `stat -f '%Lp'`，GNU（WSL、多數 Linux）的 `-f` 卻是「顯示檔案系統狀態」——那會**成功**，
# 因此在 Linux 上 BSD 寫法印出的是 `File: "..."` 而非報錯，於是每一項比對都在正確的建置
# 上失敗；而 Buildroot／BusyBox 的 guest **根本沒有 stat 這個指令**，其 applet 清單裡沒
# 有它。三者都被 `2>/dev/null` 吞掉，於是回報寫著 `expected 666 777, got  `——一個空字
# 串，它看起來像 swift_tar 沒有還原權限。
#
# 這裡曾以「先探測 `stat -c '%a'` 再分支」來解決前兩種，那個作法對的地方在於它問的是
# stat 本身而不是 `uname`——關鍵從來就不是核心是不是 Linux。zstat 把同一個道理推到底：
# 它內建於 zsh，而四個節點都在跑 zsh，於是連「這台機器的 stat 是哪一種」都不必再問，第
# 三種情況也一併消失。`-o` 會給出像 `0100646` 的八進位模式；此處只取末三位，也就是原本
# `%Lp` 的意思。
#
# The permission bits come from zsh's own zsh/stat module rather than an
# external stat.
#
# An external stat breaks in three different ways here, all of them quietly.
# BSD (macOS) spells it `stat -f '%Lp'`; GNU (WSL and most Linux) reads `-f` as
# "display filesystem status", which *succeeds* -- so on Linux the BSD form
# printed `File: "..."` rather than failing, and every comparison then
# mismatched against a correct build. The Buildroot/BusyBox guest *has no stat
# at all*: it is not in the applet list. All three are swallowed by
# `2>/dev/null`, so the report reads `expected 666 777, got  ` -- an empty
# string that looks like swift_tar failing to restore permissions.
#
# This used to probe `stat -c '%a'` and branch, which was right to ask stat
# itself rather than `uname`: a GNU stat is what matters, not a Linux kernel.
# zstat carries that further -- it is built into zsh, which every node runs, so
# there is no longer a question of which stat this machine ships, and the third
# case disappears with it. `-o` yields an octal mode such as `0100646`; the last
# three digits are what `%Lp` meant.
zmodload zsh/stat

file_mode() {  # <路徑> -> 三位八進位權限 / three octal permission digits
  local -A entry
  zstat -o -H entry -- "$1" 2>/dev/null || return 1
  print -- "${entry[mode]: -3}"
}

extract_mode() {  # <旗標...> -> "wide exec"
  rm -rf "$work/out"; mkdir -p "$work/out"
  ( cd "$work/out" && "$tar_abs" -x "$@" --zstd -f ../a.tzst ) 2>/dev/null
  print -- "$(file_mode "$work/out/src/wide.txt") $(file_mode "$work/out/src/exec.sh")"
}

print -- "swift_tar 解壓權限 / extract permissions (umask 022):"

check "666 777" "$(extract_mode)" \
  "預設仍原樣還原 / the default still restores verbatim"
check "666 777" "$(extract_mode -p)" \
  "-p 原樣還原 / -p restores verbatim"
check "666 777" "$(extract_mode --same-permissions)" \
  "--same-permissions 原樣還原 / --same-permissions restores verbatim"
check "644 755" "$(extract_mode --no-same-permissions)" \
  "--no-same-permissions 套用 umask / --no-same-permissions applies the umask"

# GNU tar 讓還原的那一方勝出，無論順序。兩種順序都測，因為只測一種的實作可能是「取最後
# 一個」而非「還原優先」，而那兩者在此處看起來相同。
# GNU tar lets the restoring form win regardless of order. Both orders are tested
# because an implementation that takes the last flag rather than preferring the
# restoring one would look identical under a single ordering.
check "666 777" "$(extract_mode --no-same-permissions -p)" \
  "-p 勝過 --no-same-permissions / -p wins"
check "666 777" "$(extract_mode -p --no-same-permissions)" \
  "順序相反時 -p 仍勝出 / -p still wins in the other order"

print -- ""
# -p 不得順帶開啟跟隨連結。兩者的解析原本相鄰，而 tarRestorePermissions 的續行
# `|| args.contains("-p") ...` 曾被一次插入切斷、接到 tarDereference 上：-p 於是既失去
# 還原權限的效果，又讓建立端開始跟隨 symlink。兩種錯誤都能編譯、都以 0 結束。
# -p must not also turn on link following. The two are parsed next to each other, and the
# continuation line of tarRestorePermissions was once severed by an insertion and attached
# to tarDereference instead: -p lost its own effect and silently gained another. Both
# compile and both exit zero.
deref_probe=$(mktemp -d)
mkdir -p "$deref_probe/t"
print -- x > "$deref_probe/target.txt"
ln -s ../target.txt "$deref_probe/t/link.txt"
if [[ -L "$deref_probe/t/link.txt" ]]; then
  # 解出後看磁碟，而非解析列表輸出：swift_tar 的 `-t -v` 只列名稱，不印 ls 風格的
  # 權限欄，所以「數開頭是 l 的行」會永遠得到 0——那會讓這個檢查在任何情況下都通過。
  # Look at what lands on disk rather than parsing a listing: swift_tar's `-t -v` prints
  # names only, so counting lines that start with l would always yield 0 and the check
  # would pass no matter what.
  ( cd "$deref_probe" && "$tar_abs" -c -p -f probe.tar t ) 2>/dev/null
  mkdir -p "$deref_probe/out"
  ( cd "$deref_probe/out" && "$tar_abs" -x -f ../probe.tar ) 2>/dev/null
  links=$( find "$deref_probe/out" -type l | wc -l | tr -d ' ' )
  check "1" "$links" "-p 不順帶跟隨連結 / -p does not also follow links"
else
  print -- "  skip 本環境無法建立真符號連結 / no real symlink here"
fi
rm -rf "$deref_probe"

if (( failures == 0 )); then
  print -- "通過 / PASS: extract permissions"
else
  print -u2 -- "失敗 / FAIL: $failures check(s)"
fi
exit $(( failures != 0 ))
