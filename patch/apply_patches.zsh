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

# A source drop has no .git, and may sit on a machine with no git at all (the Buildroot
# guest). The sources still need the patches, and "cannot tell" is the one answer this
# script must not give in silence: on 2026-10-12 a drop had to be patched on the host
# before packing, and inside the guest nothing could say whether that had been done.
#
# Without git the state is read from the text, not asked of `patch`. `patch -R --dry-run`
# was tried first and is not an answer: Apple's patch 2.0, given a reversed patch against
# unpatched sources, decides the patch is "unreversed", applies it forward and exits 0 --
# so untouched sources were reported as patched, and the --revert that followed rewrote
# them (2026-10-13, on a scratch copy). What is compared instead is plain: a patch is
# applied when every line it adds is in the file, and missing when not all of them are
# while every line it removes still is. Anything else is stale. `patch` is used only to
# make the change, and the text is read again afterwards to see that it did.
#
# 原始碼包沒有 .git，也可能落在完全沒有 git 的機器上（Buildroot guest）。那些原始碼一樣
# 需要 patch，而「無從判斷」正是本腳本不能默默給出的答案：2026-10-12 的原始碼包得先在
# host 套好 patch 再打包，而 guest 內沒有任何東西說得出那一步做了沒有。
#
# 沒有 git 時，狀態是從文字讀出來的，不是去問 `patch`。先試過 `patch -R --dry-run`，那不是
# 答案：Apple 的 patch 2.0 拿到反向 patch 對上未 patch 的原始碼時，會判定它「其實沒反」、
# 改為正向套用並以 0 結束——於是沒動過的原始碼被回報為已 patch，接著的 --revert 把它們改寫
# 了（2026-10-13，發生在暫存副本上）。改為直接比對：patch 新增的每一行都在檔案裡，就是
# 已套用；不全在、而它移除的每一行都還在，就是未套用；其餘皆為過期。`patch` 只用來做出
# 修改，做完再讀一次文字確認它真的做了。
with_git() { [[ -e $ROOT/$1/.git ]] && command -v git >/dev/null 2>&1; }
#
# The lines are compared a hunk at a time, as one run of consecutive lines with their
# context, not one by one anywhere in the file. One by one, a patch whose added lines all
# occur somewhere already (`break;`, `int ret;`, a line moved within the file) read as
# applied on untouched sources, and the build went on without it.
# 比對以 hunk 為單位，連同前後文當成一段連續的行，而不是逐行在檔案任何位置找。逐行找的時候，
# 新增的每一行本來就出現在檔案某處的 patch（`break;`、`int ret;`、在檔案內搬動的一行），對沒
# 動過的原始碼會被讀成已套用，建置就在沒有它的情況下繼續。
text_state() {   # submodule patch -> applied | missing | stale
  local sub=$1 p=$2 line counts file content="" before="" after="" nl=$'\n'
  local -i n_added=0 old=0 old0=0 new=0 added_ok=1 removed_ok=1
  while IFS= read -r line || [[ -n $line ]]; do
    if (( old > 0 || new > 0 )); then   # inside a hunk / 在 hunk 之內
      case $line in
        '+'*) after+=${line#+}$nl; new=$(( new - 1 )); n_added=$(( n_added + 1 )) ;;
        '-'*) before+=${line#-}$nl; old=$(( old - 1 )) ;;
        '\'*) ;;   # "\ No newline at end of file"
        *)    before+=${line# }$nl; after+=${line# }$nl; old=$(( old - 1 )); new=$(( new - 1 )) ;;
      esac
      if (( old <= 0 && new <= 0 )); then
        [[ $content == *"$nl$after"* ]] || added_ok=0
        # A hunk with no old lines on a file not yet there creates that file: the absence
        # is the old state. Matched as text, the empty file never held it and read as stale.
        # 沒有舊行、而檔案還不存在的 hunk 會建立該檔案：檔案不存在就是舊狀態。當成文字比對時，
        # 空的內容永遠比不到，於是被讀成過期。
        if (( old0 == 0 )) && [[ ! -e $file ]]; then :
        elif [[ $content != *"$nl$before"* ]]; then removed_ok=0; fi
      fi
      continue
    fi
    case $line in
      '+++ b/'*) file=$ROOT/$sub/${line#+++ b/}
                 content=""; [[ -r $file ]] && content=$nl$(<"$file")$nl ;;
      '@@ -'*)   # @@ -start[,count] +start[,count] @@ ; a count left out is 1
                 before=""; after=""
                 counts=${${line#@@ -}%% *}; old=1; [[ $counts == *,* ]] && old=${counts#*,}; old0=$old
                 counts=${${line#*+}%% *};   new=1; [[ $counts == *,* ]] && new=${counts#*,} ;;
    esac
  done < "$p"
  # A patch that only deletes is not decided here; call it stale so a person looks.
  # 只刪不增的 patch 不在這裡判定；歸為過期，交給人看。
  if (( n_added == 0 )); then print stale
  elif (( added_ok )); then print applied
  elif (( removed_ok )); then print missing
  else print stale; fi
}
p_state() {   # submodule patch -> applied | missing | stale
  if with_git "$1"; then
    if git -C "$1" apply --check --reverse "$2" 2>/dev/null; then print applied
    elif git -C "$1" apply --check "$2" 2>/dev/null; then print missing
    else print stale; fi
  else
    text_state "$1" "$2"
  fi
}
# What git or `patch` says is shown whenever the change did not come out as asked: "failed
# to apply" with the reason thrown away leaves nothing to act on. On success `patch` is
# kept quiet, as its "patching file ..." lines say nothing the line printed below does not.
# 修改沒有照要求完成時，一律把 git 或 `patch` 說的話印出來：「套用失敗」而原因被丟掉，就沒有
# 可以著手的東西。成功時不印 `patch` 的輸出，它那幾行「patching file ...」沒有比下面印的那一行
# 多說什麼。
p_apply() {
  local said
  if with_git "$1"; then git -C "$1" apply "$2"; return; fi
  said=$( cd "$1" && patch -p1 -N -i "$2" 2>&1 </dev/null )
  [[ $(text_state "$1" "$2") == applied ]] || { print -ru2 -- "$said"; return 1; }
}
p_reverse() {
  local said
  if with_git "$1"; then git -C "$1" apply --reverse "$2"; return; fi
  said=$( cd "$1" && patch -p1 -R -i "$2" 2>&1 </dev/null )
  [[ $(text_state "$1" "$2") == missing ]] || { print -ru2 -- "$said"; return 1; }
}

for dir in "$HERE"/*(/N); do
  sub=${dir:t}
  [[ -n "$(print -r -- "$ROOT/$sub"/*(N[1]))" ]] || {
    print -- "  – $sub — submodule 未 checkout / not checked out"
    continue
  }
  if ! with_git "$sub" && ! command -v patch >/dev/null 2>&1; then
    print -- "  ✗ $sub — 沒有 git checkout，也沒有 patch 指令，無法套用或檢查 / neither a git checkout nor a patch command: cannot apply or check"
    problems=$(( problems + 1 ))
    continue
  fi

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
    state=$(p_state "$sub" "$p")

    case "$MODE:$state" in
      check:applied)  print -- "  ✓ $sub/$name — 已套用 / applied"; already=$(( already + 1 )) ;;
      check:missing)  print -- "  ↑ $sub/$name — 未套用 / not applied"; problems=$(( problems + 1 )) ;;
      apply:applied)  print -- "  ✓ $sub/$name — 已套用，略過 / already applied"; already=$(( already + 1 )) ;;
      apply:missing)
        if p_apply "$sub" "$p"; then
          print -- "  + $sub/$name — 已套用 / applied"; applied=$(( applied + 1 ))
        else
          print -- "  ✗ $sub/$name — 套用失敗 / failed to apply"; problems=$(( problems + 1 ))
        fi ;;
      revert:applied)
        if p_reverse "$sub" "$p"; then
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
