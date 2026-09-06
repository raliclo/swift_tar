#!/usr/bin/env zsh
# =====================================================================
# apply_patches.zsh -- re-apply this tree's patches to the vendored submodules,
#                      and say clearly when one is no longer needed.
# apply_patches.zsh -- 將本樹的 patch 重新套用到 vendored submodule，並在某個 patch
#                      不再需要時明白說出來。
#
# ---------------------------------------------------------------------
# 為什麼會有這個資料夾
#
# vendored 的上游一律不改——那是規則，而這裡是那條規則的例外處，例外必須是明示的、
# 可稽核的、且**不會靜默消失**。
#
# 靜默消失正是問題所在：`sync_all.zsh --update` 會把 submodule 切到分支 tip，直接
# 覆蓋工作區的修改。一個直接改在 submodule 裡的修正，會在下一次升級時無聲不見，而
# 建置照樣成功、測試照樣通過——只是那個行為又回來了。把修改放在這裡、由腳本重貼，
# 是為了讓「它還在不在」變成一個可以執行的問題。
#
# Vendored upstreams are not edited. This folder is where that rule has exceptions,
# and an exception has to be explicit, auditable, and unable to vanish quietly.
# Vanishing quietly is the actual hazard: `sync_all.zsh --update` checks the
# submodule out at the branch tip and overwrites the working tree, so an edit made
# directly inside a submodule disappears at the next upgrade while the build still
# succeeds and the tests still pass -- only the behaviour is back.
#
# ---------------------------------------------------------------------
# 與 sync_all.zsh 的互動，必須照這個順序
#
# `sync_all.zsh` **會跳過有本地修改的 submodule**（那是刻意的：不覆蓋別人未提交的
# 工作）。而套用了 patch 的 submodule 就是「有本地修改」。因此升級的順序是：
#
#   1. ./patch/apply_patches.zsh --revert      先讓工作區乾淨
#   2. ./sync_all.zsh --update libarchive      再移動 pin
#   3. ./patch/apply_patches.zsh               重新套用
#   4. 重建、重測（見 sync_all.zsh 印出的六個步驟）
#
# 若跳過第 1 步，sync_all 會回報「跳過：有本地修改」而**什麼也不做**——升級沒有發生，
# 而畫面上看起來只是一行提示。
#
# sync_all.zsh skips submodules with local changes on purpose, and a patched
# submodule has local changes. Revert first, update, re-apply. Skipping the revert
# leaves sync_all reporting "skipped: local changes" and doing nothing.
#
# ---------------------------------------------------------------------
# 用法 / Usage:
#   ./patch/apply_patches.zsh              套用全部（已套用者略過）
#   ./patch/apply_patches.zsh --check      只檢查狀態，不改任何東西
#   ./patch/apply_patches.zsh --revert     還原所有被 patch 的檔案
#   ./patch/apply_patches.zsh --help
#
# 離開碼 / Exit status:
#   0  全部就緒（已套用，或本來就不需要）
#   1  有 patch 套用失敗或已不適用——**需要人來看**，見下方說明
# =====================================================================
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '3,57p' "${0:A}" | sed 's/^# \{0,1\}//'
  exit 0
fi

HERE=${0:A:h}
ROOT=${HERE:h}
cd "$ROOT"

MODE=apply
case "${1:-}" in
  --check)  MODE=check; shift ;;
  --revert) MODE=revert; shift ;;
  "") ;;
  *) print -ru2 -- "unknown option: $1"; exit 2 ;;
esac

typeset -i problems=0 applied=0 already=0 obsolete=0

for dir in "$HERE"/*(/N); do
  sub=${dir:t}
  [[ -d $ROOT/$sub/.git || -f $ROOT/$sub/.git ]] || {
    print -- "  – $sub — submodule 未 checkout / not checked out"
    continue
  }

  for p in "$dir"/*.patch(N); do
    name=${p:t}

    # 三個狀態要分開，因為它們要人做的事完全不同：
    #   套得上          → 套用（或 --check 時回報「缺」）
    #   反向套得上      → 已經在裡面了，什麼都不用做
    #   兩者皆否        → 上游動了。可能是上游自己修好了（那就該刪掉這個 patch），
    #                     也可能是周邊程式碼變了（那就該重做這個 patch）。
    #                     這兩種都需要人判斷，腳本不猜，也絕不用 --force 硬套。
    # Three states, because each needs a different human action: applies cleanly,
    # already applied (reverse-applies), or neither -- upstream moved, and whether
    # that means "they fixed it, delete this patch" or "redo this patch" is a
    # judgement call. The script never guesses and never forces.
    if git -C "$sub" apply --check --reverse "$p" 2>/dev/null; then
      state=applied
    elif git -C "$sub" apply --check "$p" 2>/dev/null; then
      state=missing
    else
      state=stale
    fi

    case "$MODE:$state" in
      check:applied)  print -- "  ✓ $sub/$name — 已套用 / applied"; already=$(( already + 1 )) ;;
      check:missing)  print -- "  ↑ $sub/$name — 未套用 / not applied"; problems=$(( problems + 1 )) ;;
      apply:applied)  print -- "  ✓ $sub/$name — 已套用，略過 / already applied"; already=$(( already + 1 )) ;;
      apply:missing)
        if git -C "$sub" apply "$p" 2>/dev/null; then
          print -- "  + $sub/$name — 已套用 / applied"; applied=$(( applied + 1 ))
        else
          print -- "  ✗ $sub/$name — 套用失敗 / failed to apply"; problems=$(( problems + 1 ))
        fi ;;
      revert:applied)
        if git -C "$sub" apply --reverse "$p" 2>/dev/null; then
          print -- "  - $sub/$name — 已還原 / reverted"
        else
          print -- "  ✗ $sub/$name — 還原失敗 / failed to revert"; problems=$(( problems + 1 ))
        fi ;;
      revert:missing) print -- "  – $sub/$name — 本來就沒套用 / was not applied" ;;
      *:stale)
        # 這是最重要的一個狀態，故訊息最長。
        print -- "  ! $sub/$name — 對目前的 $sub 既套不上也反套不上 / neither applies nor reverses"
        print -- "      上游已改動。請判斷是「上游修好了，刪掉這個 patch」還是"
        print -- "      「周邊變了，重做這個 patch」。不要用 --force。"
        print -- "      Upstream moved: decide whether it was fixed upstream (delete this"
        print -- "      patch) or the surroundings changed (redo it). Do not force."
        obsolete=$(( obsolete + 1 )); problems=$(( problems + 1 )) ;;
    esac
  done
done

print --
print -- "已套用 $applied  原本就在 $already  需要人看 $obsolete / applied $applied, already $already, needs a human $obsolete"

if (( problems )); then
  if [[ $MODE == check ]]; then
    print -- "以 --check 執行，未改動任何東西 / --check made no changes"
  fi
  exit 1
fi
exit 0
