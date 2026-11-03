#!/usr/bin/env zsh
# =====================================================================
# compile_tar-musl.zsh -- cross-build the static Linux release binary on a Mac
# compile_tar-musl.zsh -- 在 Mac 上交叉建置靜態的 Linux 正式版執行檔
#
#   ./compile_tar-musl.zsh aarch64     -> release/linux-aarch64/swift_tar
#   ./compile_tar-musl.zsh x86_64      -> release/linux-x86_64/swift_tar
#   ./compile_tar-musl.zsh native      -> release/swift_tar, on Linux (compile_tar-linux.zsh)
#   ./compile_tar-musl.zsh --help
#
# The public build (no LZFSE), linked fully static against musl with Swift's Static Linux
# SDK, so it runs on any Linux of that architecture: no glibc, no libbz2, no Swift runtime.
# Built here and checked on a Linux machine of the same architecture (verify_release.zsh),
# as decided with the user on 2026-10-20. Needs the swift.org toolchain and the matching SDK:
# 公開版（不含 LZFSE），以 Swift 的 Static Linux SDK 對 musl 完全靜態連結，所以在該架構的任何
# Linux 上都能執行：不需要 glibc、libbz2 或 Swift runtime。在這裡建置，再到同架構的 Linux 機器上
# 檢查（verify_release.zsh），2026-10-20 與使用者決定。需要 swift.org 的 toolchain 與相符的 SDK：
#
#   SWIFT_TOOLCHAIN   default ~/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain
#   SWIFT_STATIC_SDK  default: the swift-linux-musl directory of
#                     swift-6.4.0-RELEASE_static-linux-0.1.0, as `swift sdk install` places it
# =====================================================================
set -euo pipefail

script_path=${0:A}
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '3,21p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi
cd "${script_path:h}"
die() { print -ru2 -- "[swift_tar-musl] ERROR / 錯誤：$*"; exit 1 }
log_msg() { print -r -- "[swift_tar-musl] $*" }

# Two modes / 兩種模式:
#   aarch64 | x86_64   the release build: public, cross or native, release/linux-<arch>/swift_tar,
#                      version-musl-<arch>.txt (committed). / 正式版：公開版，交叉或原生。
#   native             the Linux dev/test build that compile_tar-linux.zsh asks for: this host's
#                      arch, on Linux only, release/swift_tar, version-linux.txt (not committed),
#                      LZFSE included when SWIFT_TAR_LZFSE=1. Linux builds are musl since
#                      2026-11-04 (the user's decision); the glibc build is gone.
#                      compile_tar-linux.zsh 要的 Linux 開發／測試建置：本機架構、僅限 Linux、
#                      release/swift_tar、version-linux.txt（不 commit），SWIFT_TAR_LZFSE=1 時含
#                      LZFSE。Linux 建置自 2026-11-04 起一律 musl（使用者的決定），glibc 建置已移除。
MODE=${1:-}
HOST=$(uname -s)
case $MODE in
  aarch64|x86_64) ARCH=$MODE ;;
  native)
    [[ $HOST == Linux ]] || die "native is the Linux dev build; on $HOST use aarch64 or x86_64 / native 僅限 Linux"
    ARCH=$(uname -m)
    [[ $ARCH == arm64 ]] && ARCH=aarch64
    [[ $ARCH == aarch64 || $ARCH == x86_64 ]] || die "unsupported host arch $ARCH / 不支援的主機架構" ;;
  *) die "usage: ./compile_tar-musl.zsh aarch64|x86_64|native / 用法" ;;
esac

# The toolchain: the swift.org one on a Mac, the swiftc on PATH (or SWIFT_PREFIX) on Linux.
# toolchain：Mac 上是 swift.org 那一份，Linux 上是 PATH（或 SWIFT_PREFIX）裡的 swiftc。
if [[ -n ${SWIFT_TOOLCHAIN:-} ]]; then
  TC=$SWIFT_TOOLCHAIN/usr/bin
elif [[ $HOST == Darwin ]]; then
  TC=$HOME/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain/usr/bin
elif [[ -n ${SWIFT_PREFIX:-} ]]; then
  TC=$SWIFT_PREFIX/bin
else
  swiftc_path=$(whence -p swiftc) || die "no swiftc on PATH; set SWIFT_PREFIX / PATH 上沒有 swiftc"
  TC=${swiftc_path:A:h}
fi
for t in swiftc clang; do
  [[ -x $TC/$t ]] || die "no $t in $TC; install the swift.org toolchain or set SWIFT_TOOLCHAIN"
done
# The SDK must match the compiler exactly, so its name comes from swiftc's own version:
# "swift-6.4-RELEASE" means 6.4.0. Searched in csv2's order: SWIFT_SDKS_PATH, then
# /workspace/opt/swift-sdks (the LinuxCS guest, whose /root is a read-only snapshot that does not
# survive a reboot), then where swiftpm installs them, ~/.swiftpm on Linux and
# ~/Library/org.swift.swiftpm on a Mac.
# SDK 必須與編譯器完全相符，所以名稱取自 swiftc 自己的版本：「swift-6.4-RELEASE」即 6.4.0。依 csv2 的
# 順序尋找：SWIFT_SDKS_PATH、/workspace/opt/swift-sdks（LinuxCS guest：它的 /root 位於唯讀快照上，
# 重開機後不保留），再來是 swiftpm 的安裝位置，Linux 為 ~/.swiftpm，Mac 為 ~/Library/org.swift.swiftpm。
swift_ver=$("$TC/swiftc" --version 2>&1 | sed -n 's/.*(swift-\([0-9][0-9.]*\)-RELEASE).*/\1/p' | head -1)
[[ -n $swift_ver ]] || die "cannot read a release version from $TC/swiftc --version"
[[ $swift_ver == *.*.* ]] || swift_ver=$swift_ver.0
if [[ -n ${SWIFT_STATIC_SDK:-} ]]; then
  SDK=$SWIFT_STATIC_SDK
else
  sdk_dirs=(${SWIFT_SDKS_PATH:+$SWIFT_SDKS_PATH} /workspace/opt/swift-sdks $HOME/.swiftpm/swift-sdks
            $HOME/Library/org.swift.swiftpm/swift-sdks)
  sdks=()
  for d in $sdk_dirs; do
    sdks+=( $d/swift-$swift_ver-RELEASE_static-linux-*.artifactbundle/swift-$swift_ver-RELEASE_static-linux-*/swift-linux-musl(N/) )
  done
  (( ${#sdks} >= 1 )) || die "no Static Linux SDK for Swift $swift_ver in ${sdk_dirs[*]}; install swift-$swift_ver-RELEASE_static-linux or set SWIFT_STATIC_SDK"
  # The first match, in the order above. On a Mac ~/.swiftpm/swift-sdks may be a link to the
  # Library one, so both can match the same SDK.
  # 依上述順序取第一個。Mac 上 ~/.swiftpm/swift-sdks 可能是指向 Library 那份的連結，兩者可能指同一份。
  SDK=${sdks[1]}
fi
src=( "$SDK"/musl-*.sdk/$ARCH(N/) )
(( ${#src} == 1 )) || die "no musl-*.sdk/$ARCH under $SDK; install the Static Linux SDK or set SWIFT_STATIC_SDK"
command -v cmake >/dev/null 2>&1 || die "cmake is required / 需要 cmake"

# llvm's binutils where the toolchain has them, else the host's: a Linux toolchain may ship
# without llvm-objcopy/llvm-objdump, and GNU objcopy/objdump read and print the same things
# for the host's own architecture (native mode builds only that one).
# toolchain 有 llvm 的 binutils 就用它，否則用主機的：Linux 的 toolchain 可能不帶 llvm-objcopy／
# llvm-objdump，而 GNU objcopy／objdump 對主機本身的架構讀寫與印出的內容相同（native 只建這一種）。
tool() {   # tool <llvm name> <host name>
  if [[ -x $TC/$1 ]]; then print -r -- "$TC/$1"
  elif [[ $HOST == Linux ]] && whence -p $2 >/dev/null; then whence -p $2
  else die "no $1 in $TC and no $2 on PATH / 找不到 $1 或 $2"
  fi
}
AR=$(tool llvm-ar ar); RANLIB=$(tool llvm-ranlib ranlib)
OBJCOPY=$(tool llvm-objcopy objcopy); OBJDUMP=$(tool llvm-objdump objdump)

# ld.lld must start, since the static link uses it. In the buildroot guest the toolchain's
# ld.lld wants a libxml2.so.2 the rootfs lacks; as compile_tar-linux.zsh did before this
# change, build exactly the symbols it imports from the libxml2 submodule, for the host.
# ld.lld 必須起得來，因為靜態連結用它。buildroot guest 裡 toolchain 的 ld.lld 需要 rootfs 沒有的
# libxml2.so.2；與本次改動前的 compile_tar-linux.zsh 相同，從 libxml2 子模組為主機建出它匯入的那些符號。
if [[ $HOST == Linux ]]; then
  LLD=$TC/ld.lld
  [[ -x $LLD ]] || die "no ld.lld in $TC; the musl link needs it / 找不到 ld.lld"
  if ! lld_err=$("$LLD" --version 2>&1 >/dev/null); then
    [[ $lld_err == *libxml2.so.2* && -f libxml2/CMakeLists.txt ]] \
      || die "ld.lld does not start: $lld_err / ld.lld 起不來"
    log_msg "ld.lld needs libxml2.so.2; building it from libxml2/ / ld.lld 需要 libxml2.so.2，從 libxml2/ 建出"
    xml_imports=(${(u)${(f)"$(readelf --dyn-syms -W "$LLD" | grep -o '[A-Za-z_0-9]*@LIBXML2_[0-9.]*')"}})
    (( ${#xml_imports} )) || die "cannot read the libxml2 symbols ld.lld imports / 讀不出 ld.lld 匯入的 libxml2 符號"
    mkdir -p build
    xml_map=$PWD/build/libxml2-linux.map
    for node in ${(u)xml_imports#*@}; do
      print -r -- "$node {"
      print -r -- "  global:"
      for imp in $xml_imports; do
        [[ ${imp#*@} == $node ]] && print -r -- "    ${imp%@*};"
      done
      print -r -- "};"
    done > "$xml_map"
    CC=$TC/clang cmake -S libxml2 -B build/libxml2-linux -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
      -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF \
      -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--version-script=$xml_map"
    cmake --build build/libxml2-linux
    [[ -e build/libxml2-linux/libxml2.so.2 ]] || ln -s libxml2.so build/libxml2-linux/libxml2.so.2
    export LD_LIBRARY_PATH=$PWD/build/libxml2-linux${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    "$LLD" --version >/dev/null || die "ld.lld still does not start with the libxml2 just built / 建好 libxml2 後 ld.lld 仍起不來"
  fi
fi

# The release build names its target; native keeps the host's "linux", so its build
# directories and version-linux.txt never touch the committed release records.
# 正式版指名目標；native 沿用主機的「linux」，所以它的 build 目錄與 version-linux.txt 不會碰到
# commit 進 repo 的正式版紀錄。
if [[ $MODE == native ]]; then
  unset SWIFT_TAR_PLATFORM
  out=release/swift_tar
else
  export SWIFT_TAR_PLATFORM=musl-$ARCH
  out=release/linux-$ARCH/swift_tar
fi
. ./platform.zsh
plat=$(swift_tar_platform)
B=$PWD/build/$plat-musl-$ARCH
[[ $MODE == native ]] || B=$PWD/build/$plat
SYSROOT=$B/sysroot
mkdir -p "$B/bin" "${out:h}"
log_msg "toolchain: $($TC/swiftc --version 2>&1 | head -1)"
log_msg "sdk:       ${src[1]}"

# ---------------------------------------------------------------------
# The SDK's sysroot, copied, with `.rodata` made read-only in every static archive. The
# Swift compiler marks `.rodata` writable and no linker takes the flag off, so linked as
# shipped the string constants and Swift's read-only metadata sat in a writable segment
# (measured on a hello world, 2026-10-20). compile_tar-linux.zsh refuses that for its own
# objects; the user decided the same day that the archives linked in here get the same
# treatment rather than the check being relaxed. A copy, so the installed SDK is untouched;
# redone when the SDK it came from changes.
# SDK 的 sysroot，複製一份，並把每個靜態封存檔的 `.rodata` 改成唯讀。Swift 編譯器把 `.rodata` 標成
# 可寫，沒有任何連結器會拿掉這個旗標，所以照原樣連結時，字串常數與 Swift 的唯讀中繼資料都落在可寫的
# 區段（2026-10-20 以 hello world 量測）。compile_tar-linux.zsh 對自己的目的檔拒絕這種情況；同日使用者
# 決定，這裡連進來的封存檔也照同樣方式處理，而不是放寬檢查。用複本，安裝好的 SDK 不受影響；來源 SDK
# 改變時重做。
# ---------------------------------------------------------------------
stamp=$SYSROOT/.swift_tar_copied_from
if [[ ! -f $stamp || $(<"$stamp") != "${src[1]}" ]]; then
  [[ $SYSROOT == $PWD/build/musl-*/sysroot || $SYSROOT == $PWD/build/linux-musl-*/sysroot ]] || die "refusing to replace $SYSROOT"
  rm -rf -- "$SYSROOT"
  log_msg "copy the sysroot and make .rodata read-only in its archives / 複製 sysroot 並把封存檔的 .rodata 改為唯讀"
  cp -pR "${src[1]}" "$SYSROOT"
  for a in "$SYSROOT"/**/*.a(N); do
    "$OBJCOPY" --set-section-flags .rodata=alloc,readonly,data "$a"
  done
  print -r -- "${src[1]}" > "$stamp"
fi

# A compiler that targets musl and this sysroot, as one command: build_libarchive.zsh runs
# "${CC:-clang}" with no room for flags, and cmake wants a single program too. It links as well
# as compiles -- lld, the SDK's own clang resources (crtbegin, compiler-rt), static -- so cmake's
# checks are real links. With compile-only checks (CMAKE_TRY_COMPILE_TARGET_TYPE
# STATIC_LIBRARY), "does library X exist" answered yes to everything: libarchive took libmd as
# found and then failed with LIBMD_LIBRARY NOTFOUND, and checks that did not fail would have
# written functions musl lacks into config.h.
# 一個指向 musl 與這個 sysroot 的編譯器，做成單一指令：build_libarchive.zsh 執行 "${CC:-clang}" 時
# 沒有放旗標的位置，cmake 也要一個單一程式。它不只編譯也能連結——lld、SDK 自己的 clang 資源（crtbegin、
# compiler-rt）、靜態——讓 cmake 的檢查是真的連結。只編譯的檢查（CMAKE_TRY_COMPILE_TARGET_TYPE
# STATIC_LIBRARY）會對「函式庫 X 存在嗎」一律回答有：libarchive 把 libmd 當成找到了，接著以
# LIBMD_LIBRARY NOTFOUND 失敗；而沒有失敗的那些檢查，會把 musl 沒有的函式寫進 config.h。
# The link flags go in only when the command links (no -c, -S, -E): passed to a compile they
# drew 99 "argument unused during compilation: '-fuse-ld=lld'" warnings. C++ gets the same
# wrapper, because zstd's project enables C++ and cmake otherwise picked the host clang++,
# whose test link failed.
# 連結旗標只在指令真的連結時（沒有 -c、-S、-E）才加上：傳給編譯時，它們引來 99 則「argument unused
# during compilation: '-fuse-ld=lld'」警告。C++ 也用同樣的 wrapper，因為 zstd 的專案啟用了 C++，否則
# cmake 會抓到 host 的 clang++，而它的測試連結失敗。
# C++ uses the SDK's libc++ (there is no libstdc++ in it), whose static link also needs
# libunwind and libc++abi named; found by linking a std::string program both ways.
# C++ 用 SDK 的 libc++（SDK 裡沒有 libstdc++），它的靜態連結還要明寫 libunwind 與 libc++abi；以一個
# 用 std::string 的程式兩種方式連結試出來的。
make_wrapper() {   # make_wrapper <path> <compiler> <always> <when linking>
  print -l '#!/bin/sh' \
    "link=\"-fuse-ld=lld -rtlib=compiler-rt -static $4\"" \
    'for a in "$@"; do case $a in -c|-S|-E) link="" ;; esac; done' \
    "exec \"$2\" --target=$ARCH-unknown-linux-musl --sysroot=\"$SYSROOT\" -resource-dir \"$SYSROOT/usr/lib/swift/clang\" $3 \$link \"\$@\"" > "$1"
  chmod 755 "$1"
}
CC=$B/bin/cc
CXX=$B/bin/c++
make_wrapper "$CC" "$TC/clang" "" ""
make_wrapper "$CXX" "$TC/clang++" "-stdlib=libc++" "-unwindlib=libunwind -lc++abi"
export SWIFT_TAR_CMAKE_TOOLCHAIN=$B/toolchain.cmake
print -l "set(CMAKE_SYSTEM_NAME Linux)" \
  "set(CMAKE_SYSTEM_PROCESSOR $ARCH)" \
  "set(CMAKE_C_COMPILER \"$CC\")" \
  "set(CMAKE_CXX_COMPILER \"$CXX\")" \
  "set(CMAKE_AR \"$AR\")" \
  "set(CMAKE_RANLIB \"$RANLIB\")" \
  "set(CMAKE_SYSROOT \"$SYSROOT\")" \
  "set(CMAKE_FIND_ROOT_PATH \"$SYSROOT\")" \
  "set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)" \
  "set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)" \
  "set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)" \
  "set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)" > "$SWIFT_TAR_CMAKE_TOOLCHAIN"

# The codecs and the patched libarchive, from the submodules, for this target. bzip2 is the
# SDK's static libbz2 (there is no bzip2 submodule).
# codec 與打過 patch 的 libarchive，從子模組為這個目標建置。bzip2 用 SDK 的靜態 libbz2（沒有 bzip2
# 子模組）。
version_file=version-$plat.txt
[[ -f $version_file ]] || : > "$version_file"
CC=$CC zsh ./build_codecs.zsh
CC=$CC ZLIB_LIBRARY="$PWD/build/zlib-$plat/libz.a" ZLIB_INCLUDE_DIR="$PWD/zlib" zsh ./build_libarchive.zsh

# LZFSE only for a native dev build that asks for it (compile_tar-linux.zsh decides); a release
# build is always the public one. / LZFSE 只給要求它的 native 開發建置（由 compile_tar-linux.zsh
# 決定）；正式版一律是公開版。
defines=(-DEXCLUDE_LZFSE)
cli_src=()
if [[ $MODE == native && ${SWIFT_TAR_LZFSE:-0} == 1 ]]; then
  [[ -f lzfse2/lzfse-cli.swift ]] || die "SWIFT_TAR_LZFSE=1 but there is no lzfse2/lzfse-cli.swift / 沒有 lzfse2"
  cli_src=($B/lzfse-cli-lib.swift)
  grep -v '^runCLI()$' lzfse2/lzfse-cli.swift > "${cli_src[1]}"
  defines=()
  log_msg "building WITH the LZFSE engine / 含 LZFSE 引擎"
else
  log_msg "building without LZFSE (-DEXCLUDE_LZFSE) / 不含 LZFSE 引擎"
fi

TEMP_VERSION=$B/swift_tar_version.swift
SWIFT_TAR_LZFSE_SOURCE=$( (( ${#cli_src} )) && print -r -- lzfse2/lzfse-cli.swift ) zsh ./generate_version.zsh "$TEMP_VERSION"

# Compile, take the writable flag off our own `.rodata`, then link: the same two steps as
# compile_tar-linux.zsh, for the same reason.
# 編譯、拿掉我們自己 `.rodata` 的可寫旗標、再連結：與 compile_tar-linux.zsh 相同的兩步，理由也相同。
target=(-target $ARCH-swift-linux-musl -sdk "$SYSROOT" -resource-dir "$SYSROOT/usr/lib/swift_static")
OBJDIR=$B/obj
rm -rf -- "$OBJDIR"
mkdir -p "$OBJDIR"
# ROOT, not $PWD, inside the subshell below: there $PWD is already the object directory.
# 下面子 shell 裡用 ROOT 而不是 $PWD：在那裡 $PWD 已經是目的檔目錄。
ROOT=$PWD
srcs=("$TEMP_VERSION" "${cli_src[@]}" swift_tar.swift rgb1.swift crypto.swift)
srcs=(${srcs:A})
log_msg "compile swift_tar / 編譯 swift_tar"
( cd "$OBJDIR" && "$TC/swiftc" -O -swift-version 6 "${target[@]}" "${defines[@]}" -c "${srcs[@]}" \
    -I "$ROOT/cmodules/PinnedZlib" -Xcc -I"$ROOT/zlib" )
for o in "$OBJDIR"/*.o; do
  "$OBJCOPY" --set-section-flags .rodata=alloc,readonly,data "$o"
done
# build_libarchive.zsh names the bridge object after the musl target, and plain for "linux".
# build_libarchive.zsh 以 musl 目標為橋接層目的檔命名，「linux」則用原名。
bridge_obj=build/libarchive_zip_bridge-$plat.o
[[ $plat == linux ]] && bridge_obj=build/libarchive_zip_bridge.o
log_msg "link $out / 連結"
"$TC/swiftc" "${target[@]}" -static-executable -static-stdlib \
  -Xclang-linker -resource-dir -Xclang-linker "$SYSROOT/usr/lib/swift/clang" \
  "$OBJDIR"/*.o "$bridge_obj" build/libarchive-$plat/libarchive/libarchive.a \
  build/xz-$plat/liblzma.a build/lz4-$plat/liblz4.a build/zstd-$plat/lib/libzstd.a build/zlib-$plat/libz.a \
  -L"$SYSROOT/usr/lib" -lbz2 -Xlinker --strip-all -o "$out"

# ---------------------------------------------------------------------
# Refusals about the result, read from the file since it cannot run here.
# 對產物的拒絕，從檔案讀出，因為它在這裡跑不了。
# ---------------------------------------------------------------------
headers=$("$OBJDUMP" -p "$out")
[[ $headers != *INTERP* ]] || die "$out has a program interpreter; it is not a static executable"
[[ $headers != *NEEDED* ]] || die "$out needs shared libraries: $(print -r -- "$headers" | grep NEEDED | tr -s ' ' | tr '\n' ' ')"
# `.rodata` must lie in a LOAD segment that is not writable.
# `.rodata` 必須位於不可寫的 LOAD 區段裡。
ro=$("$OBJDUMP" -h "$out" | awk '$2==".rodata"{print $4, $3}')
[[ -n $ro ]] || die "$out has no .rodata section to check"
ro_vma=$(( 16#${ro%% *} ))
# llvm-objdump -p prints each segment on two lines: `LOAD off .. vaddr ..`, then
# `filesz .. memsz .. flags ..`. Parsed in zsh, whose arithmetic reads 0x... (macOS awk cannot).
# llvm-objdump -p 每個區段印兩行：`LOAD off .. vaddr ..`，接著 `filesz .. memsz .. flags ..`。以 zsh
# 解析，它的算術讀得懂 0x...（macOS 的 awk 不行）。
seg="" va=""
for line in ${(f)headers}; do
  w=(${=line})
  if [[ ${w[1]} == LOAD ]]; then
    va=${w[${w[(i)vaddr]}+1]}
  elif [[ -n $va && ${w[1]} == filesz ]]; then
    ms=${w[${w[(i)memsz]}+1]}
    if (( ro_vma >= va && ro_vma < va + ms )); then seg=${w[${w[(i)flags]}+1]}; break; fi
    va=""
  fi
done
[[ -n $seg ]] || die "cannot find the LOAD segment holding .rodata"
[[ $seg != *w* ]] || die "$out keeps .rodata in a writable segment ($seg)"

# Provenance beside what the codec and libarchive builds wrote: what was linked in, from where.
# 在 codec 與 libarchive 建置寫入的內容旁，記下連進了什麼、從哪裡來。
{
  grep -vE '^(swift_stdlib_linkage|bzip2_(version|linkage|so_version|path)|libc|swift_static_sdk|swift_toolchain)=' "$version_file" || [ $? -eq 1 ]
  print -r -- swift_stdlib_linkage=static
  print -r -- bzip2_linkage=static
  print -r -- "libc=${${src[1]:h}:t:r}"
  print -r -- "swift_static_sdk=${SDK:h:t}"
  print -r -- "swift_toolchain=$($TC/swiftc --version 2>&1 | head -1)"
} > "$version_file.tmp"
mv "$version_file.tmp" "$version_file"
log_msg "built $out ($(wc -c < "$out" | tr -d ' ') bytes, static, .rodata read-only) / 已建置"
