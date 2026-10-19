#!/usr/bin/env zsh
# build_id.zsh -- the one place that decides the build id `--version` prints, sourced by
# generate_version.zsh (which stamps it into the binary) and by release.zsh (which checks it).
# build_id.zsh -- 決定 `--version` 所印 build id 的唯一一處；generate_version.zsh（把它蓋進執行檔）
# 與 release.zsh（檢查它）都 source 這個檔案。
#
#   . ./build_id.zsh
#   swift_tar_build_id <repo-dir>      # e.g. v0.1.0 / 4435482b, v0.1.0-3-g26cc4fd1, unknown
#
# Taken from csv2's build_id.zsh, whose release check went wrong three times by listing the
# shapes `git describe` can give instead of asking for one. The id always holds the commit, and
# the tag when there is one: `git describe` alone answers `v0.1.0` at a tag and nothing else, so
# the same commit built before and after tagging would read differently. The hash is always 8
# characters, not git's default, which grows with the clone and follows core.abbrev, so two
# machines would print one commit two ways.
# 取自 csv2 的 build_id.zsh：它的出貨檢查錯過三次，每次都是去列舉 `git describe` 可能給的形狀，
# 而不是直接問。id 永遠含有 commit，有 tag 時也含 tag：單用 `git describe` 在 tag 上只回答
# `v0.1.0`，於是同一個 commit 在打 tag 前後建出來會讀成兩種。雜湊一律 8 碼，不用 git 的預設值：
# 那個值隨 clone 成長、也跟著 core.abbrev，兩台機器會把同一個 commit 印成兩種。
#
# `-dirty` is decided here rather than by `git describe --dirty`, because every build rewrites
# version-<platform>.txt, and the public build (no LZFSE) rewrites it to a different content than
# the committed full build's: a release built from a clean tag would then call itself dirty. Those
# files are what the build writes, not what it reads. Every other tracked change, submodules
# included, still makes the id dirty.
# `-dirty` 在這裡判定，不交給 `git describe --dirty`：每次建置都會改寫 version-<平台>.txt，而公開版
# （不含 LZFSE）寫出的內容與已提交的完整版不同，於是從乾淨 tag 建出的正式版會自稱 dirty。那些檔案
# 是建置寫出的東西，不是它讀進的東西。其餘任何已追蹤的變更（含 submodule）仍會讓 id 帶上 dirty。
#
# Outside a git checkout (the QEMU guest builds from a drop with no .git) the id is taken from
# SWIFT_TAR_BUILD_ID when the drop's maker passed one, else `unknown`, which is true of that
# build rather than a guess. Inside a checkout, an inherited SWIFT_TAR_BUILD_ID that disagrees
# with git is refused, because whoever set it expected a binary this build will not make.
# 不在 git checkout 裡時（QEMU guest 從不含 .git 的原始碼包建置），id 取自製作原始碼包的一方傳入的
# SWIFT_TAR_BUILD_ID，沒有就是 `unknown`——那是關於該次建置的真話，不是猜測。在 checkout 裡，若
# 繼承來的 SWIFT_TAR_BUILD_ID 與 git 不符就拒絕，因為設定它的人預期的是這次不會建出的執行檔。

swift_tar_build_id() {   # swift_tar_build_id <repo-dir>
  local dir=$1 described short dirty id
  # `cd` in a subshell rather than `git -C`: on Windows zsh paths are MSYS-style /c/... and git
  # for Windows cannot change to them, while asking from inside the directory needs no path.
  # 在子 shell 裡 cd 而不用 `git -C`：Windows 上 zsh 的路徑是 MSYS 形式 /c/...，git for Windows
  # 切換不過去；從目錄裡面問就不需要路徑。
  if ! (cd "$dir" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    print -r -- "${SWIFT_TAR_BUILD_ID:-unknown}"
    return 0
  fi
  described=$(cd "$dir" && git describe --tags --always --abbrev=8 2>/dev/null) || described=""
  short=$(cd "$dir" && git rev-parse --short=8 HEAD 2>/dev/null) || short=""
  if [[ -z $described || -z $short ]]; then
    print -ru2 -- "swift_tar_build_id: $dir is a git checkout but git gave no commit; the question was malformed, not the tree"
    print -ru2 -- "swift_tar_build_id：$dir 是 git checkout，git 卻沒給出 commit；問錯的是提問方式，不是那棵樹"
    return 1
  fi
  dirty=$(cd "$dir" && git status --porcelain --untracked-files=no -- . ':(exclude)version-*.txt') || return 1
  # `v0.1.0-3-g26cc4fd1` already carries the hash; only a bare tag needs it added.
  # `v0.1.0-3-g26cc4fd1` 本來就帶雜湊；只有純 tag 需要補上。
  if [[ $described == *"$short"* ]]; then id=$described; else id="$described / $short"; fi
  [[ -z $dirty ]] || id+="-dirty"
  if [[ -n ${SWIFT_TAR_BUILD_ID:-} && $SWIFT_TAR_BUILD_ID != "$id" ]]; then
    print -ru2 -- "swift_tar_build_id: SWIFT_TAR_BUILD_ID=$SWIFT_TAR_BUILD_ID is set, but this checkout is $id; unset it"
    print -ru2 -- "swift_tar_build_id：環境設了 SWIFT_TAR_BUILD_ID=$SWIFT_TAR_BUILD_ID，但這個 checkout 是 $id；請取消它"
    return 1
  fi
  print -r -- "$id"
}
