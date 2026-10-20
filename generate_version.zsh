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
#
#   zsh ./generate_version.zsh <output-swift-file>   write the version constant
#                                                    寫出版本常數
#   zsh ./generate_version.zsh --help                print this synopsis and exit
#                                                    印出本說明後結束
set -eu

# Answered before the ${1:?} below, which would otherwise take --help as the
# output path and write a Swift file named after the flag.
# 必須在下方 ${1:?} 之前回答：否則 --help 會被當成輸出路徑，寫出一個以旗標為名的 Swift 檔。
script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '2,16p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

SCRIPT_DIR=${SWIFT_TAR_SOURCE_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
output_swift=${1:?Usage: generate_version.zsh <output-swift-file>}
build_version=$(date +%Y%m%d-%H%M%S)

. "$SCRIPT_DIR/platform.zsh"
version_file="$SCRIPT_DIR/version-$(swift_tar_platform).txt"

# The release number and the build id, printed beside the stamp. The number is VERSION's one
# line (the version a release will carry, edited before tagging); the id comes from build_id.zsh,
# which release.zsh also asks, so the two cannot disagree about its shape. Read before anything
# is written, so a malformed VERSION or a refused id stops the build instead of stamping a guess.
# 版本號與 build id，印在戳記旁邊。版本號是 VERSION 的那一行（出貨時要帶的版本，打 tag 前修改）；
# id 由 build_id.zsh 決定，release.zsh 問的也是它，所以兩者不會對形狀有不同意見。在寫出任何東西
# 之前先讀，VERSION 格式不對或 id 被拒時，建置就停下，而不是蓋上一個猜的值。
release_version=$(<"$SCRIPT_DIR/VERSION") || exit 1
if [[ $release_version != <->.<->.<-> ]]; then
    print -ru2 -- "VERSION must hold one X.Y.Z line, it holds [$release_version] / VERSION 必須是一行 X.Y.Z，實際是 [$release_version]"
    exit 1
fi
. "$SCRIPT_DIR/build_id.zsh"
build_id=$(swift_tar_build_id "$SCRIPT_DIR") || exit 1

# Refresh the build stamp and keep every other line as the builders left it.
# This used to enumerate the nine zlib/zstd/libarchive keys by name, which meant
# any key a builder added later was silently dropped on the next build — the
# macOS dynamic-linkage records added alongside this change would have vanished
# on the following compile.
# 更新版本戳，其餘各行原樣保留建置腳本寫入的內容。此處原本逐一列舉 zlib／zstd／
# libarchive 那九個鍵，導致建置腳本日後新增的任何鍵，都會在下次建置時被靜默丟棄
# ——與本次一併加入的 macOS 動態連結紀錄，下一次編譯就會消失。
current_rest=$(grep -v '^swift_tar_version=' "$version_file" 2>/dev/null || true)

# lzfse2 是編進執行檔的原始碼依賴，與 vendored codec 同一類，卻原本不在這份來源資訊裡：
# 2026-10-07 lzfse2 pin 由 06efe6c 移到 6e01a03，換掉了完整版的 LZFSE 解碼與寫入失敗處理，
# 而 macOS、Windows、WSL 三處的戳記與 version 檔都沒有變，兩個不同的執行檔帶著同一個戳記。
# 呼叫端以 SWIFT_TAR_LZFSE_SOURCE 傳入這次實際編入的 lzfse-cli.swift 路徑；空值代表公開版。
# 不由此處自行判斷，因為三個平台決定「是否納入」的方式不同（macOS 的 --no-lzfse、Linux 在
# 缺少 checkout 時自動排除、Windows 另找 ../lzfse-cli.swift），只有呼叫端知道實際結果。
# 完整版與公開版因此寫出不同的一行，在兩者之間切換建置會蓋新戳記——那正是兩個不同的執行檔。
#
# lzfse2 is compiled into the binary like the vendored codecs, yet was missing from this
# provenance: on 2026-10-07 its pin moved from 06efe6c to 6e01a03, replacing the full
# build's LZFSE decode and write-failure handling, and the stamp and version file stayed
# the same on macOS, Windows and WSL. Callers pass the lzfse-cli.swift they actually
# compiled in SWIFT_TAR_LZFSE_SOURCE, empty for the public build; only they know, since the
# three platforms decide inclusion differently. Switching between the two builds therefore
# mints a new stamp, which is right: they are different binaries.
lzfse_source=${SWIFT_TAR_LZFSE_SOURCE-}
if [[ -n $lzfse_source ]]; then
    lzfse_line="lzfse2_commit=$(git -C "${lzfse_source:h}" rev-parse HEAD 2>/dev/null || print -r -- unknown)"
else
    lzfse_line="lzfse2=excluded"
fi
current_rest=$(print -r -- "$current_rest" | grep -vE '^lzfse2(_commit)?=' || [ $? -eq 1 ])
current_rest=${current_rest:+$current_rest$'\n'}$lzfse_line

# swift_tar.swift／rgb1.swift／crypto.swift 是編進執行檔的 first-party 原始碼，但原本不是
# 版本戳的輸入，於是 --version 分不出「同一組函式庫、原始碼不同」的兩個執行檔——2026-10-14
# 記錄為 version-stamp finding（todo/todo.md）。使用者 2026-10-19 決定：把原始碼雜湊也納入
# key，改一行原始碼就鑄新戳記。雜湊這三個檔（lzfse-cli.swift 已由 lzfse2_commit 涵蓋），以
# `git hash-object --stdin` 取工作區內容的雜湊——取工作區而非已提交，是為了連未提交的編輯
# 都算進去（finding 的重現正是「改一行、尚未提交、再建」要看到戳記改變）。--stdin 不套
# autocrlf 濾鏡，Windows 與 WSL 對同一內容給相同雜湊（實測 2026-10-19）。
# 代價已知並接受：改任一 .swift 都會動 version-*.txt——d868dc3 當初要消除的 churn 有一部分
# 回來了，但只在原始碼真的改變時，不再是每次建置。非 git checkout（QEMU guest）時 git
# hash-object 失敗，退回 unknown，與 lzfse2_commit 的退路同形。
#
# swift_tar.swift, rgb1.swift and crypto.swift are the first-party sources compiled into the
# binary but were not inputs to the stamp, so --version could not tell two binaries with the
# same library set but different sources apart (the 2026-10-14 version-stamp finding in
# todo/todo.md). The user decided on 2026-10-19 to key the stamp on the sources too: a one-line
# source change mints a new stamp. Hash the three files (lzfse-cli.swift is already covered by
# lzfse2_commit) by their working-tree content via `git hash-object --stdin` -- working tree,
# not committed, so an uncommitted edit counts too (the finding's repro changes a line without
# committing and expects the stamp to move). --stdin applies no autocrlf filter, so Windows and
# WSL produce the same hash for the same content (measured 2026-10-19). The accepted cost: any
# .swift edit now churns version-*.txt -- part of what d868dc3 removed is back, but only when
# the sources actually change, no longer on every build. Outside a git checkout (the QEMU
# guest) git hash-object fails and this falls back to unknown, the same shape as lzfse2_commit.
#
# 同日稍後更正：上面「這三個檔」並不完整。libarchive_zip_bridge.c／.h 也是編進執行檔的
# first-party 原始碼（三個平台都編譯並連結它），patch/ 底下的修補也會在 build_libarchive.zsh
# 裡套進 vendored libarchive——而 libarchive_commit 只記 submodule 的 commit，記不到修補。發現
# 經過：修好 bridge 讀 ZIP 名稱的 bug、重建後 --version 仍是舊戳記，正是本 finding 原本的形狀。
# 現在雜湊三個 .swift、bridge 的 .c 與 .h、以及每個 patch/*/*.patch。修補以 LC_ALL=C 排序，使
# Windows 與 WSL 的 locale 排序差異不會改變串接順序；只串接內容、不含路徑，所以兩個平台的
# 前綴不同也不影響雜湊。
#
# Correction later the same day: "the three files" above was incomplete. libarchive_zip_bridge.c
# and .h are first-party sources compiled into the binary too (all three platforms build and link
# them), and the patches under patch/ are applied to the vendored libarchive in
# build_libarchive.zsh -- libarchive_commit records the submodule's commit, not the patches on
# top. Found when a fix to the bridge's ZIP name lookup rebuilt with the old stamp, which is this
# finding's original shape. Hashed now: the three .swift files, the bridge .c and .h, and every
# patch/*/*.patch. The patches are ordered with LC_ALL=C so a Windows/WSL locale difference in
# collation cannot reorder the concatenation; only contents are concatenated, not paths, so the
# two platforms' different prefixes do not enter the hash.
# The list goes through a variable first. Written inline as ${(f)$(...)}, the nested command
# substitution is split into words and joined back with spaces before (f) sees it, so the three
# patch paths arrived as one argument and cat failed on it -- while the pipeline still printed a
# hash, of the five other files. / 清單先存進變數。若直接寫成 ${(f)$(...)}，巢狀的命令替換會先被
# 切字再以空格接回，(f) 看到的已無換行，三個 patch 路徑成了一個引數、cat 對它失敗——而管線仍印
# 出一個雜湊，只涵蓋另外五個檔。
# Later the same evening the `LC_ALL=C sort` went too: on Windows this runs after the vcvars PATH
# has been put in front, where `sort` is C:\Windows\System32\sort.exe -- not GNU sort, and its
# order is not byte order. The glob is now ordered by zsh itself under a local LC_ALL=C, with no
# external command and no list to split. / 當晚稍後連 `LC_ALL=C sort` 也拿掉了：Windows 上本段在
# vcvars 的 PATH 被放到前面之後才執行，此時 `sort` 是 C:\Windows\System32\sort.exe——不是 GNU sort，
# 排序也不是位元組順序。現在由 zsh 自己在 local LC_ALL=C 下排序 glob，不經外部指令，也沒有清單要切。
() { local LC_ALL=C; patch_files=("$SCRIPT_DIR"/patch/*/*.patch(N)) }
stamp_inputs=("$SCRIPT_DIR/swift_tar.swift" "$SCRIPT_DIR/rgb1.swift" "$SCRIPT_DIR/crypto.swift"
              "$SCRIPT_DIR/libarchive_zip_bridge.c" "$SCRIPT_DIR/libarchive_zip_bridge.h"
              "${patch_files[@]}")
source_hash=$(cat -- "${stamp_inputs[@]}" \
    | git -C "$SCRIPT_DIR" hash-object --stdin 2>/dev/null || true)
[[ -n $source_hash ]] || source_hash=unknown
source_line="swift_tar_source=$source_hash"
current_rest=$(print -r -- "$current_rest" | grep -v '^swift_tar_source=' || [ $? -eq 1 ])
current_rest=${current_rest:+$current_rest$'\n'}$source_line

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
# 就不該靠時間戳回答——verifications/release_matrix.csv2 記的是各執行檔的 sha256，那才是
# 答案；以 verifications/record_release.zsh --record 追加。該檔案在本註解寫成時尚不存在，
# 於是「被讓出的性質有一個明載的替代品，而替代品不在」持續了十天；2026-09-04 補上。
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
# never a question a timestamp could answer -- verifications/release_matrix.csv2
# records each built binary's sha256, and that is the answer; append to it with
# verifications/record_release.zsh --record. That file did not exist when this
# comment was written, so for ten days the property given up here had a documented
# replacement that was not there. Supplied 2026-09-04.
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

# The number and the id go in as ONE literal, `swift_tar <number> (<id>)`, so the binary holds
# that exact text: release.zsh checks a cross-built Linux binary, which the Mac cannot run, by
# finding it there. Two separate constants did not: Swift keeps a literal of 15 bytes or less
# inside the instructions, not as text, and `0.1.0` or an untagged `6029537d` is that short.
# 版本號與 id 合成**一個**字面值 `swift_tar <版本> (<id>)`，讓執行檔裡有這段一字不差的文字：Mac 執行
# 不了交叉建置的 Linux 執行檔，release.zsh 就靠在檔案裡找到它來檢查。分成兩個常數時做不到：Swift
# 會把 15 bytes 以下的字面值放在指令裡，不是存成文字，而 `0.1.0` 或未打 tag 的 `6029537d` 正是這麼短。
{
    printf 'let swiftTarBuildVersion = "%s"\n' "$build_version"
    printf 'let swiftTarIdentity = "swift_tar %s (%s)"\n' "$release_version" "$build_id"
} > "$output_swift"
echo "[INFO] swift_tar version: $release_version ($build_id) $build_version / swift_tar 版本：$release_version（$build_id）$build_version"
