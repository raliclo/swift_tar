#!/usr/bin/env zsh
# test_submodule_pins.zsh -- the build scripts never move a checked-out submodule behind your back.
# test_submodule_pins.zsh -- 建置腳本絕不在背後移動已 checkout 的子模組。
#
#   ./test/test_submodule_pins.zsh          # run / 執行
#   ./test/test_submodule_pins.zsh --help   # this synopsis / 本說明
#
# Exercises ensure_submodule_pins (submodule_pins.zsh) in a throwaway superproject with one
# submodule. Until 2026-10-19 the build scripts ran `git submodule update --init` instead, which
# put a deliberately moved submodule back at the recorded commit without a word, so a whole WSL
# suite "verified" newer codecs while building the old ones. Case 2 is that regression: the
# submodule must still be where it was left, and the run must stop. Paths stay relative to the
# working directory: on Windows this zsh and Git for Windows map /tmp differently.
# 在一個只含一個子模組的拋棄式 superproject 裡測 ensure_submodule_pins（submodule_pins.zsh）。
# 2026-10-19 之前建置腳本直接執行 `git submodule update --init`，會把刻意移動過的子模組無聲地
# 放回記錄的 commit，於是一整套 WSL 測試「驗證」了新版 codec、實際建的卻是舊版。第 2 項就是那個
# 回歸：子模組必須仍停在原處，且執行必須停下。路徑一律相對於工作目錄：Windows 上本 zsh 與
# Git for Windows 對 /tmp 的對應不同。
set -u

script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  for l in "${(@f)$(<"$script_path")}"; do
    [[ $l == '#!'* ]] && continue
    [[ $l == '#'* ]] || break
    l=${l#\#}; printf '%s\n' "${l# }"
  done
  exit 0
fi
ROOT="${script_path:h:h}"
. "$ROOT/submodule_pins.zsh"

pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)) }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)) }

TMP=$(mktemp -d) || { printf 'FAIL: mktemp -d\n'; exit 1 }
trap 'rm -rf -- "$TMP"' EXIT
cd -q "$TMP"

# A local file-path submodule needs protocol.file allowed (git >= 2.38.1); identity is fixed so
# the commits work on a machine with none configured. / 本機路徑的子模組需允許 protocol.file
# （git >= 2.38.1）；身分固定，使沒有設定身分的機器也能提交。
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q up && print -r -- one > up/f && git -C up add f && git -C up commit -qm c1 \
  && print -r -- two > up/f && git -C up commit -qam c2 || { printf 'FAIL: building the upstream repo\n'; exit 1 }
c1=$(git -C up rev-parse HEAD~1); c2=$(git -C up rev-parse HEAD)
git init -q super && cd -q super \
  && git submodule add -q ../up sub && git -C sub checkout -q "$c1" && git add sub \
  && git commit -qm 'record c1' || { printf 'FAIL: building the superproject\n'; exit 1 }

# 1. At the recorded commit: nothing to do. / 停在記錄的 commit：無事可做。
rc=0; out=$(ensure_submodule_pins sub 2>&1) || rc=$?
[[ $rc == 0 && -z $out ]] && ok "at the recorded commit: exit 0, silent" \
  || bad "at the recorded commit: exit 0, silent (rc $rc; $out)"

# 2. Moved and not staged: stop, say both commits, and leave it where it is.
#    已移動但未暫存：停下、說出兩個 commit，並把它留在原處。
git -C sub checkout -q "$c2"
rc=0; out=$(ensure_submodule_pins sub 2>&1) || rc=$?
[[ $rc == 1 ]] && ok "moved, not staged: exit 1" || bad "moved, not staged: exit 1 (rc $rc)"
[[ $out == *${c2[1,9]}* && $out == *${c1[1,9]}* && $out == *'git add sub'* ]] \
  && ok "moved, not staged: names both commits and the two ways out" \
  || bad "moved, not staged: names both commits and the two ways out ($out)"
[[ $(git -C sub rev-parse HEAD) == $c2 ]] \
  && ok "moved, not staged: the submodule is NOT moved back (the 2026-10-19 regression)" \
  || bad "moved, not staged: the submodule is NOT moved back (now at $(git -C sub rev-parse --short HEAD))"

# 3. Staged: builds, uncommitted. / 已暫存：可建置，不必先提交。
git add sub
rc=0; out=$(ensure_submodule_pins sub 2>&1) || rc=$?
[[ $rc == 0 && $(git -C sub rev-parse HEAD) == $c2 ]] && ok "staged bump: exit 0 and stays at the new commit" \
  || bad "staged bump: exit 0 and stays at the new commit (rc $rc; $out)"

# 4. Not checked out at all: checked out, as before. / 完全未 checkout：照舊 checkout。
git submodule deinit -q -f sub
rc=0; out=$(ensure_submodule_pins sub 2>&1) || rc=$?
[[ $rc == 0 && -e sub/.git && $(git -C sub rev-parse HEAD) == $c2 ]] \
  && ok "not checked out: checked out at the recorded commit" \
  || bad "not checked out: checked out at the recorded commit (rc $rc; $out)"

printf -- '-----------------------------------------\nPASS: %s  FAIL: %s\n' "$pass" "$fail"
(( fail == 0 ))
