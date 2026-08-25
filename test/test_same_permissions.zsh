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

# BSD stat spells the permission bits `-f '%Lp'`; GNU coreutils spells them
# `-c '%a'` and reads `-f` as "show filesystem status" instead -- which succeeds,
# so the BSD form on Linux printed `File: "..."` rather than failing. Every
# comparison then mismatched against a correct build. Decided once here, not per
# call, and by asking stat rather than by branching on `uname`: a GNU stat is
# what matters, not a Linux kernel.
# BSD 的 stat 以 `-f '%Lp'` 取權限位元；GNU coreutils 則是 `-c '%a'`，且會把 `-f`
# 讀成「顯示檔案系統狀態」——那會成功，所以在 Linux 上 BSD 寫法印出的是 `File: "..."`
# 而非報錯，於是每一項比對都在正確的建置上失敗。此處只判斷一次，且是問 stat 而不是
# 看 `uname`：關鍵在於是不是 GNU stat，而不是核心是不是 Linux。
if stat -c '%a' . >/dev/null 2>&1; then
  mode_of() { stat -c '%a' "$1" 2>/dev/null }
else
  mode_of() { stat -f '%Lp' "$1" 2>/dev/null }
fi

extract_mode() {  # <旗標...> -> "wide exec"
  rm -rf "$work/out"; mkdir -p "$work/out"
  ( cd "$work/out" && "$tar_abs" -x "$@" --zstd -f ../a.tzst ) 2>/dev/null
  print -- "$(mode_of "$work/out/src/wide.txt") $(mode_of "$work/out/src/exec.sh")"
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
if (( failures == 0 )); then
  print -- "通過 / PASS: extract permissions"
else
  print -u2 -- "失敗 / FAIL: $failures check(s)"
fi
exit $(( failures != 0 ))
