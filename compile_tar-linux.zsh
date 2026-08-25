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
#   * libarchive is linked shared from the sysroot. The appliance this was
#     first proven on has no cmake, so the bundled static build is not an
#     option there; a distro with cmake can still set LIBARCHIVE_STATIC=1.
#     libarchive 改以 sysroot 的共享庫連結。本腳本首次驗證所在的設備沒有 cmake，
#     故內附靜態建置在該處不可行；有 cmake 的發行版仍可設定 LIBARCHIVE_STATIC=1。
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
#   LIBARCHIVE_STATIC set to 1 to build the bundled static libarchive instead
#
# Defaults target the buildroot aarch64 appliance under
# sos/linux_kernal_vm_interactive; on an ordinary distro both are auto-detected.
# 預設值對應 sos/linux_kernal_vm_interactive 下的 buildroot aarch64 設備；在一般
# 發行版上兩者皆會自動偵測。
#
# Output / 輸出：release/swift_tar
# =====================================================================
set -euo pipefail
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
for h in zlib.h bzlib.h lzma.h zstd.h lz4.h archive.h; do
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

log_msg "Generate version constants / 產生版本常數"
# zsh, not sh: the callee declares `#!/usr/bin/env zsh` and `sh script` ignores
# the shebang, so it would only keep working for as long as that script happens
# to stay POSIX. Same for build_libarchive.zsh below.
# 使用 zsh 而非 sh：被呼叫者宣告 `#!/usr/bin/env zsh`，而 `sh script` 會忽略
# shebang，故只在該腳本剛好維持 POSIX 的期間內可行。下方的 build_libarchive.zsh
# 亦同。
zsh ./generate_version.zsh "$TEMP_VERSION"

log_msg "Compile the libarchive ZIP bridge / 編譯 libarchive ZIP bridge"
"$CLANG" -O2 -fPIC -I"$SYSROOT/include" \
    -c libarchive_zip_bridge.c -o build/libarchive_zip_bridge.o

ARCHIVE_LINK=(-L"$SYSROOT/lib" -larchive)
if [[ "${LIBARCHIVE_STATIC:-0}" == 1 ]]; then
    command -v cmake >/dev/null 2>&1 || die "LIBARCHIVE_STATIC=1 需要 cmake / requires cmake"
    zsh ./build_libarchive.zsh
    ARCHIVE_LINK=("build/libarchive-$(swift_tar_platform)/libarchive/libarchive.a")
fi

ZLIB_MODULEMAP="build/zlib-sysroot.modulemap"
cat > "$ZLIB_MODULEMAP" <<MODMAP
module zlib [system] {
    header "$SYSROOT/include/zlib.h"
    export *
}
MODMAP

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

log_msg "Build swift_tar / 建置 swift_tar"
"$SWIFTC" -O "${SWIFT_DEFINES[@]}" \
    "$TEMP_VERSION" "${CLI_SRC[@]}" swift_tar.swift rgb1.swift crypto.swift \
    build/libarchive_zip_bridge.o \
    -Xcc -fmodule-map-file="$ZLIB_MODULEMAP" \
    -Xcc -I"$SYSROOT/include" \
    -I"$SYSROOT/include" \
    "${ARCHIVE_LINK[@]}" \
    -L"$SYSROOT/lib" -lz -lbz2 -llzma -lzstd -llz4 \
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
record_provenance() {
    local version_file="version-$(swift_tar_platform).txt"
    local tmp_version="$version_file.tmp"
    {
        grep -vE '^(zlib|bzip2|lz4|xz|zstd|libarchive)_(so_version|path|linkage)=' \
            "$version_file" 2>/dev/null || true
        record_linked zlib       'libz\.so'
        record_linked bzip2      'libbz2\.so'
        record_linked lz4        'liblz4\.so'
        record_linked xz         'liblzma\.so'
        record_linked zstd       'libzstd\.so'
        record_linked libarchive 'libarchive\.so'
    } > "$tmp_version"
    mv "$tmp_version" "$version_file"
    log_msg "Recorded linked libraries in $version_file / 已將連結的函式庫記入 $version_file"
}
record_provenance || log_msg "WARNING: could not record linkage provenance / 警告：無法記錄連結來源"

./release/swift_tar --version 2>&1 | head -3 || true
