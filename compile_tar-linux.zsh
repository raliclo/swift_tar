#!/usr/bin/env zsh
# =====================================================================
# compile_tar-linux.zsh — build swift_tar as a Linux ELF.
# compile_tar-linux.zsh — 將 swift_tar 建置為 Linux ELF。
#
# Separate from compile_tar.zsh rather than a branch inside it. compile_tar.zsh
# is macOS throughout: it requires /opt/homebrew/lib *.dylib, builds a bundled
# static libarchive with cmake, reads linkage back with otool, and installs into
# /opt/homebrew/bin. None of that holds here, and threading five conditionals
# through it would make the macOS path harder to read for no gain.
# 與 compile_tar.zsh 分開，而非在其中加分支。compile_tar.zsh 通篇都是 macOS 的作法：
# 需要 /opt/homebrew/lib 的 *.dylib、以 cmake 建置內附的靜態 libarchive、用 otool
# 讀回連結資訊、安裝到 /opt/homebrew/bin。這些在此都不成立，而為此在其中穿插五個
# 條件判斷，只會讓 macOS 路徑更難讀且毫無收穫。
#
# Differences from the macOS build / 與 macOS 版的差異：
#   * libarchive is the bundled static copy when cmake and libarchive/ are present,
#     as on macOS and Windows, because this tree's patches reach only that copy.
#     Without them it falls back to the sysroot's shared library and says so: the
#     appliance this was first proven on had no cmake. LIBARCHIVE_STATIC=0 or =1
#     decides outright.
#     有 cmake 與 libarchive/ 時使用內附的靜態版，與 macOS、Windows 相同，因為本樹的
#     patch 只進得了那一份。缺少時退回 sysroot 的共享庫並明白說出來：本腳本首次驗證
#     所在的設備沒有 cmake。LIBARCHIVE_STATIC=0 或 =1 直接決定。
#   * swift_tar.swift does `import zlib`, and cmodules/zlib/module.modulemap
#     points at the bundled zlib submodule. We link the sysroot's libz, so the
#     header must be the sysroot's too — a module map is generated against it
#     rather than initialising a submodule whose zlib we are not linking.
#     swift_tar.swift 有 `import zlib`，而 cmodules/zlib/module.modulemap 指向內附的
#     zlib submodule。我們連結的是 sysroot 的 libz，header 就必須同樣來自 sysroot
#     ——故改為針對它產生 module map，而非去初始化一個我們並未連結其 zlib 的
#     submodule。
#
# Environment / 環境變數:
#   SWIFT_PREFIX      Swift toolchain prefix (contains bin/swiftc, bin/clang)
#   SYSROOT           prefix holding include/ and lib/ for the codecs
#   LIBARCHIVE_STATIC 1 = bundled static libarchive, 0 = the sysroot's shared one;
#                     unset = static when cmake and libarchive/ are present
#   CODECS_STATIC     1 = zlib, liblzma, liblz4, libzstd from the submodules, 0 = the
#                     sysroot's shared ones; unset = static when cmake and all four
#                     source trees are present
#
# Defaults target the buildroot aarch64 appliance under
# sos/linux_kernal_vm_interactive; on an ordinary distro both are auto-detected.
# 預設值對應 sos/linux_kernal_vm_interactive 下的 buildroot aarch64 設備；在一般
# 發行版上兩者皆會自動偵測。
#
# Output / 輸出：release/swift_tar
#
# Usage / 用法:
#   ./compile_tar-linux.zsh          build for this Linux host
#                                    在此 Linux 主機上建置
#   ./compile_tar-linux.zsh --help   print this synopsis and exit, building nothing
#                                    印出本說明後結束，不進行任何建置
# =====================================================================
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '3,54p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

cd "$(dirname "$0")"
. ./platform.zsh

die() { print -u2 -- "[swift_tar-linux] ERROR / 錯誤：$*"; exit 1; }
# log_msg, not log: `log` is a zsh builtin. A function shadows it only from the
# point of definition, so a call placed above this line silently resolves to the
# builtin, which rejects any argument with "zsh:log:1: too many arguments" and
# returns 1 -- under the `set -e` above, that aborts the build with a message
# pointing at zsh rather than at the missing definition. Nothing here calls it
# early today; the rename removes the trap rather than documenting it.
# 命名為 log_msg 而非 log：`log` 是 zsh 的 builtin。函式只從定義處起遮蔽它，故位於
# 本行之上的呼叫會靜默地解析到 builtin，而 builtin 收到任何參數都會以
# 「zsh:log:1: too many arguments」拒絕並回傳 1——在上方的 `set -e` 下，這會讓建置
# 中止，而訊息指向 zsh 而非「函式尚未定義」。目前並無任何提前呼叫；此處改名是為了
# 移除該陷阱，而不是替它寫註解。
log_msg() { print -- "[swift_tar-linux] $*"; }

# The appliance layout first, then the system one. Probed rather than assumed so
# the same script serves both without a flag.
# 先看設備配置，再看系統配置。以探測而非假設決定，使同一支腳本無需旗標即可服務兩者。
if [[ -z "${SWIFT_PREFIX:-}" ]]; then
    if [[ -x /workspace/opt/swift/usr/bin/swiftc ]]; then
        SWIFT_PREFIX=/workspace/opt/swift/usr
    elif whence -p swiftc >/dev/null 2>&1; then
        SWIFT_PREFIX=${${:-$(whence -p swiftc)}:A:h:h}
    else
        die "找不到 swiftc；請設定 SWIFT_PREFIX / no swiftc found; set SWIFT_PREFIX"
    fi
fi
if [[ -z "${SYSROOT:-}" ]]; then
    if [[ -d /workspace/sysroot/include ]]; then
        SYSROOT=/workspace/sysroot
    else
        SYSROOT=/usr
    fi
fi

SWIFTC="$SWIFT_PREFIX/bin/swiftc"
CLANG="$SWIFT_PREFIX/bin/clang"
[[ -x "$SWIFTC" ]] || die "找不到 swiftc / no swiftc at: $SWIFTC"
[[ -x "$CLANG"  ]] || CLANG=$(whence -p clang) || die "找不到 clang / no clang found"

log_msg "swift prefix: $SWIFT_PREFIX"
log_msg "sysroot:      $SYSROOT"

# Name the missing header rather than letting the compiler emit a wall of
# errors that all trace back to one absent package.
# 直接指出缺少哪個 header，而不是讓編譯器噴出一整片、其實全源自單一套件缺失的錯誤。
for h in bzlib.h; do
    [[ -f "$SYSROOT/include/$h" ]] || die "sysroot 缺少 header / missing header: $SYSROOT/include/$h"
done

# LZFSE is private and shipped as a submodule; without it the binary can neither
# create nor read the LZFSE family, exactly as ./compile_tar.zsh --no-lzfse.
# Detected rather than hardcoded: the appliance has no lzfse2 checkout, a full
# clone does.
# LZFSE 為私有並以 submodule 形式提供；沒有它時，產出的執行檔既不能建立也不能讀取
# LZFSE 家族，與 ./compile_tar.zsh --no-lzfse 相同。此處以偵測而非寫死決定：設備上沒有
# lzfse2 checkout，完整 clone 則有。
# EXCLUDE_LZFSE=1 in the environment forces exclusion even where lzfse2 is
# checked out, matching `./compile_tar.zsh --no-lzfse`.
#
# Detection alone cannot express "I have the engine and do not want it", and
# there are callers in exactly that position: multissh builds its own copy of
# swift_tar with -DEXCLUDE_LZFSE on macOS, and had no way to ask for the same
# thing here. On a full clone this script therefore built WITH the private
# engine, and the caller was left with a build it never asked for and could not
# turn off.
#
# That full-engine build also failed on WSL until 2026-08-25, and the reason
# recorded here was wrong: it said Swift on Linux already provides
# `autoreleasepool(invoking:)`. It does not -- were that so, the EXCLUDE_LZFSE
# build would have collided too, and it always succeeded. Two shims were being
# compiled into one module: swift_tar.swift's under `#if os(Linux)` and
# lzfse-cli.swift's under `#if !canImport(ObjectiveC)`, overlapping on Linux
# and nowhere else. swift_tar.swift's is now `#if os(Linux) && EXCLUDE_LZFSE`.
#
# 在環境中設定 EXCLUDE_LZFSE=1，即使 lzfse2 已 checkout 也強制排除，
# 與 `./compile_tar.zsh --no-lzfse` 一致。
#
# 單靠偵測無法表達「我有這個引擎，但我不要它」，而確實有呼叫端正處於這個位置：
# multissh 在 macOS 上是以 -DEXCLUDE_LZFSE 建置自己那份 swift_tar 的，卻無從在此提出
# 相同要求。於是在完整 clone 上，本腳本會帶著私有引擎建置，呼叫端因此得到一個它從未
# 要求、也關不掉的建置。
#
# 含引擎的建置在 2026-08-25 之前於 WSL 上也會失敗，而此處原本記載的原因是錯的：它說
# Linux 的 Swift 本就提供 `autoreleasepool(invoking:)`。並非如此——若真如此，
# EXCLUDE_LZFSE 的建置也會一併衝突，而它一直都成功。真正的原因是同一個 module 編入了
# 兩份 shim：swift_tar.swift 的 `#if os(Linux)` 與 lzfse-cli.swift 的
# `#if !canImport(ObjectiveC)`，兩者僅在 Linux 重疊。swift_tar.swift 那份已改為
# `#if os(Linux) && EXCLUDE_LZFSE`。
SWIFT_DEFINES=(-DEXCLUDE_LZFSE)
CLI_SRC=()
TEMP_CLI=""
if [[ -n ${EXCLUDE_LZFSE:-} && ${EXCLUDE_LZFSE} != 0 ]]; then
    log_msg "EXCLUDE_LZFSE 已設定；不含 LZFSE 引擎 / set; building with -DEXCLUDE_LZFSE"
elif [[ -f lzfse2/lzfse-cli.swift ]]; then
    TEMP_CLI="$(mktemp -t lzfse-cli-lib.XXXXXX).swift"
    grep -v "^runCLI()$" lzfse2/lzfse-cli.swift > "$TEMP_CLI"
    CLI_SRC=("$TEMP_CLI")
    SWIFT_DEFINES=()
    log_msg "lzfse2 present; building WITH the LZFSE engine / 含 LZFSE 引擎"
else
    log_msg "no lzfse2 checkout; building with -DEXCLUDE_LZFSE / 不含 LZFSE 引擎"
fi

mkdir -p build release
TEMP_VERSION="build/swift_tar_version.swift"
trap 'rm -f "$TEMP_CLI"' EXIT

# Static when it can be, shared otherwise. This tree's libarchive patches reach only the
# library build_libarchive.zsh builds; a sysroot's shared libarchive is whatever the distro
# shipped. Shared used to be the default here, and on 2026-10-12 that is how a fix made on
# macOS (patch 0002, FIFOs in ZIP) turned out never to have reached Linux: the build
# succeeded, and `-c --zip` refused a FIFO. So: unset means static wherever cmake and the
# libarchive sources are both present, and the shared fallback says what it lacks instead
# of passing for the same thing. LIBARCHIVE_STATIC=0 or =1 still decides outright.
# 能靜態就靜態，否則才共享。本樹對 libarchive 的 patch 只進得了 build_libarchive.zsh 建出的
# 那一份；sysroot 的共享庫則是發行版給什麼就是什麼。這裡原本預設共享，2026-10-12 就是因此
# 才發現一項在 macOS 完成的修正（patch 0002，ZIP 內的 FIFO）從未到達 Linux：建置成功，而
# `-c --zip` 拒絕 FIFO。因此：未設定時，只要 cmake 與 libarchive 原始碼都在就走靜態；退回
# 共享時明說少了什麼，而不是看起來一樣。LIBARCHIVE_STATIC=0 或 =1 仍直接決定。
if [[ -z "${LIBARCHIVE_STATIC:-}" ]]; then
    if command -v cmake >/dev/null 2>&1 && [[ -f libarchive/CMakeLists.txt ]]; then
        LIBARCHIVE_STATIC=1
    else
        LIBARCHIVE_STATIC=0
        log_msg "NOTICE: no cmake or no libarchive/ sources; linking the sysroot's shared libarchive."
        log_msg "        patch/libarchive/*.patch are NOT in this build: -c --zip cannot store a FIFO"
        log_msg "        and compresses on one thread whatever -n is."
        log_msg "注意：缺 cmake 或 libarchive/ 原始碼，改連結 sysroot 的共享 libarchive。"
        log_msg "      本次建置不含 patch/libarchive/*.patch：-c --zip 存不了 FIFO，"
        log_msg "      且不論 -n 為何都只用一個執行緒壓縮。"
    fi
fi

# The codecs follow the same rule, for the same reason: a pin in this tree means nothing
# on a platform that links whatever the sysroot has. zlib, liblzma, liblz4 and libzstd are
# built from the submodules by build_codecs.zsh when cmake and all four sources are
# present; bzip2 has no submodule and stays the sysroot's. CODECS_STATIC=0 or =1 decides
# outright.
# codec 依同一條規則，理由也相同：在連結 sysroot 現有版本的平台上，本樹的 pin 毫無意義。
# cmake 與四份原始碼都在時，zlib、liblzma、liblz4、libzstd 由 build_codecs.zsh 從
# submodule 建出；bzip2 沒有 submodule，維持使用 sysroot 的。CODECS_STATIC=0 或 =1 直接決定。
if [[ -z "${CODECS_STATIC:-}" ]]; then
    if command -v cmake >/dev/null 2>&1 && [[ -f zlib/CMakeLists.txt && -f xz/CMakeLists.txt \
          && -f lz4/build/cmake/CMakeLists.txt && -f zstd/build/cmake/CMakeLists.txt ]]; then
        CODECS_STATIC=1
    else
        CODECS_STATIC=0
        log_msg "NOTICE: no cmake or no codec sources; linking the sysroot's zlib, liblzma, liblz4 and libzstd."
        log_msg "        The submodule pins for those four are NOT what this build contains."
        log_msg "注意：缺 cmake 或 codec 原始碼，改連結 sysroot 的 zlib、liblzma、liblz4、libzstd。"
        log_msg "      本次建置的內容不是這四者的 submodule pin。"
    fi
fi
if [[ "$CODECS_STATIC" == 1 ]]; then
    command -v cmake >/dev/null 2>&1 || die "CODECS_STATIC=1 需要 cmake / requires cmake"
    CC="$CLANG" zsh ./build_codecs.zsh
    CODEC_LINK=(build/xz-linux/liblzma.a build/lz4-linux/liblz4.a build/zstd-linux/lib/libzstd.a
                build/zlib-linux/libz.a -L"$SYSROOT/lib" -lbz2)
    ZLIB_FOR_ARCHIVE_LIB="$PWD/build/zlib-linux/libz.a"
    ZLIB_FOR_ARCHIVE_INC="$PWD/zlib"
else
    for h in zlib.h lzma.h zstd.h lz4.h; do
        [[ -f "$SYSROOT/include/$h" ]] || die "sysroot 缺少 header / missing header: $SYSROOT/include/$h"
    done
    CODEC_LINK=(-L"$SYSROOT/lib" -lz -lbz2 -llzma -lzstd -llz4)
    ZLIB_FOR_ARCHIVE_LIB="$SYSROOT/lib/libz.so"
    ZLIB_FOR_ARCHIVE_INC="$SYSROOT/include"
fi

ARCHIVE_LINK=(-L"$SYSROOT/lib" -larchive)
ARCHIVE_INCLUDE="$SYSROOT/include"
if [[ "$LIBARCHIVE_STATIC" == 1 ]]; then
    command -v cmake >/dev/null 2>&1 || die "LIBARCHIVE_STATIC=1 需要 cmake / requires cmake"
    # cmake must find the same zlib and compiler this script links with, not whatever it
    # would discover on its own. / cmake 必須找到本腳本連結的同一份 zlib 與編譯器。
    CC="$CLANG" ZLIB_LIBRARY="${ZLIB_LIBRARY:-$ZLIB_FOR_ARCHIVE_LIB}" ZLIB_INCLUDE_DIR="${ZLIB_INCLUDE_DIR:-$ZLIB_FOR_ARCHIVE_INC}" \
        zsh ./build_libarchive.zsh
    ARCHIVE_LINK=("build/libarchive-$(swift_tar_platform)/libarchive/libarchive.a")
    ARCHIVE_INCLUDE="libarchive/libarchive"
else
    [[ -f "$SYSROOT/include/archive.h" ]] || die "sysroot 缺少 header / missing header: $SYSROOT/include/archive.h"
fi

# After the choice above, and here rather than left to build_libarchive.zsh: the bridge
# must be compiled against the headers of the libarchive it is linked with, and with
# -fPIC, which a PIE link on Linux requires and that script (written for macOS) omits.
# 放在上述選擇之後，且在這裡編譯而不交給 build_libarchive.zsh：bridge 必須對著它所連結的那份
# libarchive 的 header 編譯，並帶 -fPIC——Linux 的 PIE 連結需要它，而那支腳本（為 macOS 而寫）
# 沒有帶。
#
# SWIFT_TAR_ZIP_PARALLEL only with the static library: the bridge's threaded compression
# writes through patch/libarchive/0003, which a sysroot's shared libarchive does not have.
# Without the flag -c --zip compresses on one thread, whatever -n says.
# 只有靜態函式庫才帶 SWIFT_TAR_ZIP_PARALLEL：bridge 的多執行緒壓縮是經由 patch/libarchive/0003
# 寫出，而 sysroot 的共享 libarchive 沒有它。不帶這個旗標時，不論 -n 為何，-c --zip 都只用
# 一個執行緒壓縮。
log_msg "Compile the libarchive ZIP bridge / 編譯 libarchive ZIP bridge"
bridge_flags=()
if [[ "$LIBARCHIVE_STATIC" == 1 ]]; then
    bridge_flags=(-DSWIFT_TAR_ZIP_PARALLEL -I"$ZLIB_FOR_ARCHIVE_INC")
fi
"$CLANG" -O2 -fPIC "${bridge_flags[@]}" -I"$ARCHIVE_INCLUDE" -I"$SYSROOT/include" \
    -c libarchive_zip_bridge.c -o build/libarchive_zip_bridge.o

# After build_libarchive.zsh, not before. generate_version.zsh reuses the stamp when
# the rest of version-linux.txt matches the committed copy, and build_libarchive.zsh
# is what writes libarchive_version/commit there. Called first, it compared against
# the previous build's libarchive and reused the stamp across a pin move -- the same
# ordering f4386b7 fixed in compile_tar.zsh on 2026-09-20, missed here until the
# 2026-09-27 review.
#
# zsh, not sh: the callee declares `#!/usr/bin/env zsh` and `sh script` ignores
# the shebang, so it would only keep working for as long as that script happens
# to stay POSIX. Same for build_libarchive.zsh above.
#
# 放在 build_libarchive.zsh 之後，不是之前。generate_version.zsh 在 version-linux.txt
# 其餘內容與已提交版本相同時會重用戳記，而寫入 libarchive_version/commit 的正是
# build_libarchive.zsh。先呼叫它，就會拿上一次建置的 libarchive 來比對，於是 pin 移動後
# 戳記仍被重用——與 f4386b7 於 2026-09-20 在 compile_tar.zsh 修掉的順序問題相同，這裡
# 一直漏到 2026-09-27 審查才發現。
#
# 使用 zsh 而非 sh：被呼叫者宣告 `#!/usr/bin/env zsh`，而 `sh script` 會忽略
# shebang，故只在該腳本剛好維持 POSIX 的期間內可行。上方的 build_libarchive.zsh 亦同。
log_msg "Generate version constants / 產生版本常數"
# 這次實際編入的 lzfse-cli.swift；公開版為空。/ The lzfse-cli.swift compiled in; empty for the public build.
SWIFT_TAR_LZFSE_SOURCE=$([[ -n $TEMP_CLI ]] && print -r -- lzfse2/lzfse-cli.swift) zsh ./generate_version.zsh "$TEMP_VERSION"

# The zlib that Swift imports must be the zlib that is linked: the pinned submodule's
# header through cmodules/PinnedZlib when the codecs are static, the sysroot's through a
# generated module map otherwise.
# Swift 匯入的 zlib 必須就是連結的那一份：codec 為靜態時，經 cmodules/PinnedZlib 使用固定
# submodule 的 header；否則經產生的 module map 使用 sysroot 的。
if [[ "$CODECS_STATIC" == 1 ]]; then
    ZLIB_SWIFT_FLAGS=(-I "$PWD/cmodules/PinnedZlib" -Xcc -I"$PWD/zlib")
else
    ZLIB_MODULEMAP="$PWD/build/zlib-sysroot.modulemap"
    cat > "$ZLIB_MODULEMAP" <<MODMAP
module zlib [system] {
    header "$SYSROOT/include/zlib.h"
    export *
}
MODMAP
    ZLIB_SWIFT_FLAGS=(-Xcc -fmodule-map-file="$ZLIB_MODULEMAP" -Xcc -I"$SYSROOT/include" -I"$SYSROOT/include")
fi

# Record the Swift runtime location in the binary. Without an RPATH it can only
# start with LD_LIBRARY_PATH set, and that does not survive the boundaries a
# real system has: /etc/profile.d runs for login shells only, `su -` rebuilds
# the environment, and sudo deletes LD_* outright. Every one of those failures
# reports the same unhelpful "error while loading shared libraries".
# 把 Swift runtime 的位置寫進執行檔。沒有 RPATH 時它只能在設定了 LD_LIBRARY_PATH 的
# 情況下啟動，而該前提撐不過真實系統的邊界：/etc/profile.d 只對 login shell 生效、
# `su -` 會重建環境、sudo 更會直接刪除 LD_*。這三種失敗都只報同一句無用的
# "error while loading shared libraries"。
SWIFT_RUNTIME_DIR="$SWIFT_PREFIX/lib/swift/linux"

# -swift-version 6, matching compile_tar.zsh and compile_tar-win.zsh. Linux was the
# last platform without it, and the reason it waited is worth keeping: the flag was
# not held back because nobody had tried it, but because trying it produced errors
# that only Linux shows. glibc's `stdin`/`stderr` are mutable globals; Darwin's and
# ucrt's are not, so macOS and Windows compiled clean while Linux reported eight --
# four in crypto.swift (fixed in 8c552cf by taking the descriptor number rather than
# the FILE*) and four in the private engine (fixed in lzfse2 665c56a by using that
# file's own eprint()). Same source, three answers, and the difference is in libc.
#
# Both were fixed by removing the reference, never by annotating the diagnostic away.
#
# Measured in the QEMU aarch64 guest with this script before the flag was committed
# here, all four combinations:
#   EXCLUDE_LZFSE=1 x Swift 5   rc=0      EXCLUDE_LZFSE=1 x Swift 6   rc=0
#   full engine     x Swift 5   rc=0      full engine     x Swift 6   rc=0
# Swift 6 mode adds no warning the Swift 5 build did not already produce.
#
# -swift-version 6，與 compile_tar.zsh、compile_tar-win.zsh 一致。Linux 是最後一個補上
# 的平台，而它之所以等到現在值得記下來：旗標不是因為沒人試過而被擱置，而是試了會出現
# 只有 Linux 才看得到的錯誤。glibc 的 `stdin`／`stderr` 是可變全域，Darwin 與 ucrt 的
# 不是，所以 macOS 與 Windows 編得乾淨，Linux 卻報八個——crypto.swift 四個（8c552cf 改
# 為取描述子編號而非 FILE*）、私有引擎四個（lzfse2 665c56a 改用該檔既有的 eprint()）。
# 同一份原始碼、三種結果，差別在 libc。兩處都是以「拿掉那個引用」修好，不是用標註壓下。
#
# 旗標提交至此之前，已在 QEMU aarch64 guest 內以本腳本實測四種組合，全部 rc=0；
# Swift 6 模式未新增任何 Swift 5 建置沒有的警告。
# The link, and why it is not left to the defaults. GNU ld used to warn "release/swift_tar
# has a LOAD segment with RWX permissions", and it was right -- the whole image, code
# included, was one writable and executable segment. Traced on 2026-10-13: Swift 6.3.3 on
# aarch64 emits the protocol conformance descriptors of payload-free enums (here TarCodec
# and WriteBackend) into a section named `.rodata` with the writable flag set; any
# `enum E { case a, b }` does it, however the conformance is declared. GNU ld places
# sections by name, so the flag landed on the output .rodata, which sits in the text
# segment. Three things are done about it, and the third is the one that removes the cause:
#
#   * -z separate-code for GNU ld, so code has a segment of its own whatever else happens.
#   * lld whenever the toolchain's ld.lld can start. It places by flags. On the Buildroot
#     guest ld.lld does not start by itself: lld is one binary for four linkers and needs
#     libxml2.so.2 at load time for the Windows one. When that is the reason, libxml2 is
#     built with clang from the libxml2/ submodule and put on the linker's library path
#     only. Without ld.lld, or without the means to make it start, the link uses the
#     system ld and says so.
#   * the writable flag is taken off `.rodata` between compile and link (below).
#
# Measured in the VM the same day, with the flag removed: lld gives R, R E, RW, RW and GNU
# ld gives R, R E, R, RW; both have GNU_RELRO over .data.rel.ro and .got, and .rodata is in
# a read-only segment under both. Before the flag was removed, neither linker could do
# that: GNU ld had no GNU_RELRO at all and lld put .rodata in the writable data segment.
#
# 連結，以及為什麼不交給預設值。GNU ld 原本會警告「release/swift_tar has a LOAD segment with
# RWX permissions」，而且它說得對——整個映像（含程式碼）是單一個可寫又可執行的區段。
# 2026-10-13 追查：aarch64 上的 Swift 6.3.3 把無 payload enum（此處是 TarCodec 與
# WriteBackend）的 protocol conformance descriptor 放進一個名為 `.rodata`、卻帶可寫旗標的
# section；任何 `enum E { case a, b }` 都會如此，不論 conformance 怎麼宣告。GNU ld 依名稱安置
# section，於是旗標落到輸出的 .rodata 上，而它位在 text 區段裡。對此做了三件事，其中第三件
# 才是消除成因的那一件：
#
#   * 給 GNU ld 的 -z separate-code，讓程式碼無論如何都有自己的區段。
#   * 工具鏈的 ld.lld 起得來時就用 lld，它依旗標安置。在 Buildroot guest 上 ld.lld 自己
#     起不來：lld 是四個連結器共用的一支執行檔，載入時就需要 libxml2.so.2（給 Windows 那
#     一個用）。原因是這個時，就用 clang 從 libxml2/ submodule 建出 libxml2，並且只放進
#     連結器的函式庫路徑。沒有 ld.lld、或沒有辦法讓它起來時，改用系統的 ld 並明白說出來。
#   * 在編譯與連結之間把 `.rodata` 的可寫旗標拿掉（見下）。
#
# 同日在 VM 上實測，旗標拿掉之後：lld 得到 R、R E、RW、RW，GNU ld 得到 R、R E、R、RW；兩者
# 都有涵蓋 .data.rel.ro 與 .got 的 GNU_RELRO，.rodata 在兩者之下都位於唯讀區段。旗標拿掉
# 之前，兩個連結器都做不到：GNU ld 完全沒有 GNU_RELRO，lld 則把 .rodata 放進可寫的資料區段。
LLD="$SWIFT_PREFIX/bin/ld.lld"
LINK_ENV=()
LINKER_FLAGS=(-Xlinker -z -Xlinker separate-code)
if [[ -x "$LLD" ]]; then
    lld_err=""
    if ! lld_err=$("$LLD" --version 2>&1 >/dev/null); then
        if [[ "$lld_err" == *libxml2.so.2* && -f libxml2/CMakeLists.txt ]] && command -v cmake >/dev/null 2>&1; then
            log_msg "ld.lld needs libxml2.so.2; building it from libxml2/ / ld.lld 需要 libxml2.so.2，從 libxml2/ 建出"
            # lld asks for a file named libxml2.so.2 whose symbols carry the version nodes
            # it was linked against. libxml2 2.14 changed the soname and dropped its
            # version script, so both are supplied here: the nodes are read from lld's own
            # imports, and the old file name is a link to the library just built. The
            # loader looks a library up by file name, not by the soname inside it.
            # lld 要的是名為 libxml2.so.2 的檔案，且符號帶有它當初連結時的版本節點。libxml2
            # 自 2.14 起換了 soname，也不再附 version script，所以兩者都在這裡補上：節點由
            # lld 自己的匯入表讀出，舊檔名則是指向剛建好的函式庫的連結。載入器依檔名找
            # 函式庫，不看裡面的 soname。
            xml_imports=(${(u)${(f)"$(readelf --dyn-syms -W "$LLD" | grep -o '[A-Za-z_0-9]*@LIBXML2_[0-9.]*')"}})
            (( ${#xml_imports} )) || die "讀不出 ld.lld 匯入的 libxml2 符號 / cannot read the libxml2 symbols ld.lld imports"
            xml_map="$PWD/build/libxml2-linux.map"
            for node in ${(u)xml_imports#*@}; do
                print -r -- "$node {"
                print -r -- "  global:"
                for imp in $xml_imports; do
                    [[ "${imp#*@}" == "$node" ]] && print -r -- "    ${imp%@*};"
                done
                print -r -- "};"
            done > "$xml_map"
            CC="$CLANG" cmake -S libxml2 -B build/libxml2-linux -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
                -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF \
                -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--version-script=$xml_map"
            cmake --build build/libxml2-linux
            [[ -e build/libxml2-linux/libxml2.so.2 ]] || ln -s libxml2.so build/libxml2-linux/libxml2.so.2
            LINK_ENV=(env LD_LIBRARY_PATH="$PWD/build/libxml2-linux${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}")
            "${LINK_ENV[@]}" "$LLD" --version >/dev/null \
                || die "libxml2 建好後 ld.lld 仍起不來 / ld.lld still does not start with the libxml2 just built"
            lld_err=""
        fi
    fi
    if [[ -z "$lld_err" ]]; then
        LINKER_FLAGS=(-use-ld=lld)
    else
        log_msg "NOTICE: ld.lld does not start ($lld_err); linking with the system ld."
        log_msg "注意：ld.lld 起不來，改用系統的 ld 連結。"
    fi
else
    log_msg "NOTICE: no ld.lld in the toolchain; linking with the system ld."
    log_msg "注意：工具鏈沒有 ld.lld，改用系統的 ld 連結。"
fi

# Compile and link are separate steps so the writable flag can be taken off `.rodata` in
# between. The flag is the compiler's (see above) and no linker removes it: GNU ld and lld
# both leave every string constant and all of Swift's read-only metadata writable at run
# time. Nothing needs it writable at load -- of the 1657 dynamic relocations in the lld
# build, none lands in `.rodata` (measured 2026-10-13). Whether the Swift runtime writes
# there later is not something a measurement can rule out; if it does, the write now
# faults instead of succeeding. Decided with the user the same day.
# The objects go to a directory of their own because swiftc -c names each after its source
# and writes it to the working directory.
#
# 編譯與連結分成兩步，中間才能把 `.rodata` 的可寫旗標拿掉。旗標是編譯器給的（見上），沒有
# 任何連結器會拿掉它：GNU ld 與 lld 都讓每一個字串常數與 Swift 的唯讀中繼資料在執行期可寫。
# 載入時沒有東西需要它可寫——lld 建置的 1657 筆動態重定位中，沒有任何一筆落在 `.rodata`
# （2026-10-13 實測）。Swift runtime 之後會不會寫它，量測排除不了；若會，那次寫入現在會
# 觸發錯誤，而不是成功。同日與使用者討論後決定。
# 目的檔放進自己的目錄，因為 swiftc -c 以原始檔命名每一個目的檔，並寫到工作目錄。
log_msg "Build swift_tar / 建置 swift_tar"
OBJDIR="build/swift-obj-linux"
rm -rf "$OBJDIR"
mkdir -p "$OBJDIR"
swift_srcs=("$TEMP_VERSION" "${CLI_SRC[@]}" swift_tar.swift rgb1.swift crypto.swift)
swift_srcs=(${swift_srcs:A})
( cd "$OBJDIR" && "$SWIFTC" -O -swift-version 6 "${SWIFT_DEFINES[@]}" -c "${swift_srcs[@]}" "${ZLIB_SWIFT_FLAGS[@]}" )

OBJCOPY="$SWIFT_PREFIX/bin/llvm-objcopy"
[[ -x "$OBJCOPY" ]] || OBJCOPY=$(whence -p objcopy) || OBJCOPY=""
if [[ -n "$OBJCOPY" ]]; then
    for o in "$OBJDIR"/*.o; do
        "$OBJCOPY" --set-section-flags .rodata=alloc,readonly,data "$o"
    done
else
    log_msg "NOTICE: no llvm-objcopy or objcopy; .rodata stays writable in this build."
    log_msg "注意：沒有 llvm-objcopy 或 objcopy；本次建置的 .rodata 仍可寫。"
fi

"${LINK_ENV[@]}" "$SWIFTC" "$OBJDIR"/*.o \
    build/libarchive_zip_bridge.o \
    "${ARCHIVE_LINK[@]}" \
    "${CODEC_LINK[@]}" \
    "${LINKER_FLAGS[@]}" \
    -Xlinker -rpath -Xlinker "$SWIFT_RUNTIME_DIR" \
    -Xlinker -rpath -Xlinker "$SYSROOT/lib" \
    -o release/swift_tar

log_msg "Built ./release/swift_tar / 已建置 ./release/swift_tar"

# An RPATH that failed to apply looks identical to one that worked, until the
# binary is first started from a clean environment.
# 未生效的 RPATH 與正常的無從區分，直到執行檔第一次在乾淨環境下被啟動為止。
if command -v readelf >/dev/null 2>&1; then
    readelf -d release/swift_tar 2>/dev/null | grep -E 'RUNPATH|RPATH' \
        || log_msg "WARNING: no RUNPATH recorded / 警告：未記錄 RUNPATH"
    # A build whose code is writable is refused, whatever the linker chose to say about
    # it: the warning this replaces scrolled past for weeks. See -z separate-code above.
    # 程式碼可寫的建置一律拒絕，不論連結器有沒有說話：這裡取代的那則警告已經在畫面上
    # 捲過好幾週。見上方的 -z separate-code。
    if readelf -lW release/swift_tar | grep -E '^ +LOAD ' | grep -q 'RWE'; then
        die "release/swift_tar 有同時可寫又可執行的 LOAD 區段 / has a LOAD segment that is both writable and executable"
    fi
    # Likewise for .rodata once the flag was taken off above: if it is writable again, an
    # input this script did not rewrite brought the flag back.
    # .rodata 亦然：上面已拿掉旗標，若它又變成可寫，就是有本腳本沒改寫到的輸入把旗標帶回來。
    rodata=($(readelf -SW release/swift_tar | grep -E '\] \.rodata +PROGBITS' | sed 's/^.*\] //'))
    if [[ -n "$OBJCOPY" && "${rodata[7]:-}" == *W* ]]; then
        die "release/swift_tar 的 .rodata 可寫（旗標 ${rodata[7]}）/ .rodata is writable (flags ${rodata[7]})"
    fi
fi

# Record what the binary actually links, read back from the binary. The macOS
# build does the same with otool; here ldd resolves each SONAME to a real file
# and the filename carries the upstream version — libzstd.so.1.5.7 is zstd
# 1.5.7. That is a better record than macOS gets: a Mach-O current version can
# disagree with upstream, as liblzma's does.
# 記錄執行檔實際連結了什麼，且直接自執行檔讀回。macOS 版以 otool 做同一件事；此處
# 由 ldd 將各 SONAME 解析為實際檔案，而檔名即帶有上游版本——libzstd.so.1.5.7 就是
# zstd 1.5.7。這比 macOS 那邊得到的紀錄更好：Mach-O 的 current version 可能與上游
# 不一致，liblzma 正是如此。
#
# Read from readelf's DT_NEEDED list and resolve against the sysroot, rather
# than from ldd. ldd is absent on this buildroot appliance — busybox does not
# provide it and buildroot does not install glibc's — and an earlier version of
# this block used it inside `set -e`, so a successful build reported failure
# with rc=127 after the binary had already been produced and run.
# 改由 readelf 的 DT_NEEDED 清單讀取，並針對 sysroot 解析，而非使用 ldd。此
# buildroot 設備上沒有 ldd——busybox 不提供，buildroot 也沒安裝 glibc 那份——而本段
# 先前的版本在 `set -e` 下使用它，導致一次成功的建置在執行檔都已產出並跑過之後，
# 仍以 rc=127 回報失敗。
record_linked() {        # key  soname-prefix
    local key="$1" pat="$2" soname real ver
    soname=$(readelf -d release/swift_tar 2>/dev/null \
        | awk -F'[][]' -v p="$pat" '/NEEDED/ && $2 ~ "^" p {print $2; exit}') || return 0
    [[ -n "$soname" ]] || return 0
    real=$(readlink -f "$SYSROOT/lib/$soname" 2>/dev/null) || real=""
    [[ -n "$real" ]] || real="$soname (unresolved / 未解析)"
    ver=${${real:t}#*.so.}
    printf '%s_so_version=%s\n%s_path=%s\n%s_linkage=dynamic\n' "$key" "$ver" "$key" "$real" "$key"
}

# Provenance is a record about the build, not a part of it. If it cannot be
# written the build is still good, so this reports and continues instead of
# taking the exit code with it.
# provenance 是關於本次建置的紀錄，而非建置的一部分。即使寫不出來，建置本身仍然有效，
# 故此處回報後繼續，而不是把結束碼一併帶走。
#
# libarchive is read back here only when it is linked shared. With LIBARCHIVE_STATIC=1,
# build_libarchive.zsh has already written libarchive_version/commit/linkage=static from
# the submodule; this block used to strip libarchive_linkage and then find no libarchive.so
# to read back, so the static build's record lost the key that says it is static (Windows/
# WSL verification, 2026-10-07). The same shape compile_tar.zsh had until 2026-09-17: a
# filter deleting a key it has no way to rewrite. A shared build strips libarchive_version/
# commit as well, since they describe a submodule that is then not what was linked.
#
# grep's status 1 (nothing printed) is tolerated; any other failure goes to the caller,
# which reports it -- no longer `2>/dev/null || true`.
#
# 只有在 libarchive 以共享庫連結時，才在這裡讀回它。LIBARCHIVE_STATIC=1 時，
# build_libarchive.zsh 已依 submodule 寫入 libarchive_version／commit／linkage=static；本段原本會
# 刪掉 libarchive_linkage，接著找不到 libarchive.so 可讀回，於是靜態建置的紀錄失去了「它是靜態」
# 這個鍵（Windows／WSL 驗證，2026-10-07）。compile_tar.zsh 在 2026-09-17 之前也是同樣的形狀：
# 過濾器刪掉了自己無法重寫的鍵。共享庫建置則一併清掉 libarchive_version／commit，因為它們描述的
# submodule 此時並不是實際連結的東西。
#
# 容忍 grep 的狀態 1（沒有輸出）；其他失敗交給呼叫端回報——不再是 `2>/dev/null || true`。
record_provenance() {
    local version_file="version-$(swift_tar_platform).txt"
    local tmp_version="$version_file.tmp"
    # Static codecs are recorded by build_codecs.zsh (version, commit, linkage=static) and
    # must survive this filter; shared ones are read back from the binary here, and any
    # static record left by an earlier build must go.
    # 靜態 codec 由 build_codecs.zsh 記錄（version、commit、linkage=static），不能被這個過濾器
    # 刪掉；共享的則在此從執行檔讀回，而先前建置留下的靜態紀錄必須清掉。
    local strip='^bzip2_(so_version|path|linkage)='
    if [[ "$CODECS_STATIC" != 1 ]]; then
        strip+='|^(zlib|lz4|xz|zstd)_(so_version|path|linkage|version|commit)='
    fi
    if [[ "$LIBARCHIVE_STATIC" == 1 ]]; then
        strip+='|^libarchive_(so_version|path)='
    else
        strip+='|^libarchive_(so_version|path|linkage|version|commit)='
    fi
    {
        grep -vE "$strip" "$version_file" || [ $? -eq 1 ]
        [[ "$CODECS_STATIC" == 1 ]] || record_linked zlib       'libz\.so'
        record_linked bzip2      'libbz2\.so'
        [[ "$CODECS_STATIC" == 1 ]] || record_linked lz4        'liblz4\.so'
        [[ "$CODECS_STATIC" == 1 ]] || record_linked xz         'liblzma\.so'
        [[ "$CODECS_STATIC" == 1 ]] || record_linked zstd       'libzstd\.so'
        [[ "$LIBARCHIVE_STATIC" == 1 ]] || record_linked libarchive 'libarchive\.so'
    } > "$tmp_version"
    mv "$tmp_version" "$version_file"
    log_msg "Recorded linked libraries in $version_file / 已將連結的函式庫記入 $version_file"
}
record_provenance || log_msg "WARNING: could not record linkage provenance / 警告：無法記錄連結來源"

./release/swift_tar --version 2>&1 | head -3 || true
