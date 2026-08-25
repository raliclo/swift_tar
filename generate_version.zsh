#!/usr/bin/env zsh
# Generate the build-time Swift version constant and refresh version-<plat>.txt.
# 產生建置時 Swift 版本常數，並更新 version-<平台>.txt。
#
# One file per platform. A shared version.txt meant a macOS build overwrote the
# stamp and the linkage provenance recorded by the Windows build scripts, and
# vice versa — the two describe different binaries linked against differently
# built libraries, so they were never the same fact to begin with.
# 每個平台一個檔案。共用 version.txt 會使 macOS 建置覆寫 Windows 建置腳本所記錄的
# 版本戳與連結來源，反之亦然——兩者描述的是連結到不同建置產物的不同執行檔，本來就
# 不是同一件事實。
set -eu

SCRIPT_DIR=${SWIFT_TAR_SOURCE_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
output_swift=${1:?Usage: generate_version.zsh <output-swift-file>}
build_version=$(date +%Y%m%d-%H%M%S)

. "$SCRIPT_DIR/platform.zsh"
version_file="$SCRIPT_DIR/version-$(swift_tar_platform).txt"

# Refresh the build stamp and keep every other line as the builders left it.
# This used to enumerate the nine zlib/zstd/libarchive keys by name, which meant
# any key a builder added later was silently dropped on the next build — the
# macOS dynamic-linkage records added alongside this change would have vanished
# on the following compile.
# 更新版本戳，其餘各行原樣保留建置腳本寫入的內容。此處原本逐一列舉 zlib／zstd／
# libarchive 那九個鍵，導致建置腳本日後新增的任何鍵，都會在下次建置時被靜默丟棄
# ——與本次一併加入的 macOS 動態連結紀錄，下一次編譯就會消失。
current_rest=$(grep -v '^swift_tar_version=' "$version_file" 2>/dev/null || true)

# 若除了時間戳以外，這份來源資訊與 git 中已記錄的完全相同，就沿用已記錄的時間戳，並把
# 檔案寫回與 git 相同的內容——不產生新的戳記。
#
# 理由是代價已經付過了。這個檔案每建置一次就改變一次，而 helper/build_swift_tar.zsh 有
# 一道守門會在 version 檔有未提交變更時拒絕建置。兩者相加的結果是：跑完一次測試（測試會
# 建置）之後，下一次建置必定被拒，訊息說「有未提交變更」，而那個變更只是一個沒有人在乎
# 的時間戳。2026-08-25 一天之內就擋了四次。
#
# 這確實改變了 swift_tar_version 的語意：它不再是「這個執行檔何時被編譯」，而是「這份來源
# 資訊何時改變」。那才是這個檔案其餘每一行在講的事，而「執行檔是不是我以為的那一個」本來
# 就不該靠時間戳回答——release_matrix.csv 記的是各執行檔的 sha256，那才是答案。
#
# 不是 git checkout 時（例如刻意不含 .git 的 QEMU guest），`git show` 會失敗，於是行為與
# 原本完全相同：照常蓋上新的時間戳。
#
# When this provenance is identical to what git already records apart from the
# stamp, reuse the recorded stamp and write the file back to match git exactly
# -- do not mint a new one.
#
# The reason is a cost already paid. This file changed on every build, and
# helper/build_swift_tar.zsh carries a guard that refuses to build while the
# version files have uncommitted changes. Together they meant that after any
# test run -- tests build -- the next build was refused, reporting "uncommitted
# changes" that were a timestamp nobody was reading. That blocked four builds in
# one day on 2026-08-25.
#
# This does change what swift_tar_version means: no longer "when this binary was
# compiled" but "when this provenance last changed", which is what every other
# line in the file is about. Whether a binary is the one you think it is was
# never a question a timestamp could answer -- release_matrix.csv records each
# shipped binary's sha256, and that is the answer.
#
# Outside a git checkout -- the QEMU guest is provisioned without .git on
# purpose -- `git show` fails and the behaviour is exactly as before: stamp anew.
# 比對的是「排序後」的其餘各行，而不是逐行原樣比對，因為順序會變而內容沒變：
# build_libarchive.zsh 會重寫本檔並把 libarchive_* 那幾個鍵放到不同位置，於是三行內容
# 一字不差、diff 卻顯示三刪三增。逐行比對會因此永遠不成立，這個機制也就永遠不會生效。
# 順序在此不帶任何資訊——每一行都是獨立的 key=value——所以以集合比較才是對的問法。
# 相同時直接寫回 git 中的內容，順序也一併回到正規狀態。
#
# The comparison is of the *sorted* remaining lines rather than line-by-line,
# because the order moves while the content does not: build_libarchive.zsh
# rewrites this file with the libarchive_* keys in a different position, so
# three identical lines show up as three deletions and three insertions. A
# line-by-line comparison would therefore never hold and this would never
# trigger. Order carries no information here -- every line is an independent
# key=value -- so comparing as a set is the right question. When they match, the
# committed content is written back, which normalises the order too.
committed=$(git -C "$SCRIPT_DIR" show "HEAD:${version_file:t}" 2>/dev/null || true)
committed_rest=$(print -r -- "$committed" | grep -v '^swift_tar_version=' | sort || true)
committed_stamp=$(print -r -- "$committed" | grep '^swift_tar_version=' | head -1 || true)
committed_stamp=${committed_stamp#swift_tar_version=}
current_sorted=$(print -r -- "$current_rest" | sort)

if [[ -n $committed && -n $committed_stamp && $current_sorted == $committed_rest ]]; then
    build_version=$committed_stamp
    print -r -- "$committed" > "$version_file"
else
    {
        echo "swift_tar_version=$build_version"
        print -r -- "$current_rest"
    } > "$version_file.tmp"
    mv "$version_file.tmp" "$version_file"
fi

printf 'let swiftTarBuildVersion = "%s"\n' "$build_version" > "$output_swift"
echo "[INFO] swift_tar version: $build_version / swift_tar 版本：$build_version"
