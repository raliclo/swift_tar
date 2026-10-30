#!/usr/bin/env zsh
# win_clang_cmake.zsh -- sourced by the Windows dependency builders: find the Swift toolchain's
# clang/clang-cl and Visual Studio's nmake, and set the CMake arguments that build with them.
# win_clang_cmake.zsh -- 由 Windows 相依建置腳本 source：找出 Swift 工具鏈的 clang／clang-cl 與
# Visual Studio 的 nmake，並設定以它們建置的 CMake 參數。
#
#   . ./win_clang_cmake.zsh
#   win_clang_cmake clang    "$out_dir" || exit 1    # GNU driver: zstd, zlib / GNU 驅動：zstd、zlib
#   win_clang_cmake clang-cl "$out_dir" || exit 1    # MSVC driver: libarchive / MSVC 驅動：libarchive
#   cmake -S src -B build "${win_cmake_args[@]}" ...
#
# Sets win_cmake_args (generator, compiler, make program, Release, archive output directory) and
# win_cc (the compiler path, C:/ form, as CMakeCache.txt records it).
# 設定 win_cmake_args（產生器、編譯器、make 程式、Release、靜態庫輸出目錄）與 win_cc（編譯器路徑，
# C:/ 形式，與 CMakeCache.txt 記錄的相同）。
#
# Why NMake: the Visual Studio generator always drives cl.exe, so building with clang needs a
# generator that takes CMAKE_C_COMPILER. Ninja did, but the Swift toolchain ships none and on the
# PC this was written on the only one was a copy bundled with scoop's perl (2026-10-30). nmake.exe
# ships with the VS C++ build tools swiftc already needs, so no new dependency. It is found
# through vswhere and passed as CMAKE_MAKE_PROGRAM, so the builders run without vcvars loaded:
# clang and clang-cl locate the MSVC headers and libraries themselves. nmake builds serially.
# NMake is single-configuration, so CMAKE_ARCHIVE_OUTPUT_DIRECTORY puts each library where the
# old multi-config tree did (<dir>/Release), the path build_libarchive-win.zsh and
# compile_tar-win.zsh read.
# 為何用 NMake：Visual Studio 產生器一律驅動 cl.exe，用 clang 建置就需要會接受 CMAKE_C_COMPILER 的
# 產生器。Ninja 可以，但 Swift 工具鏈不附，而寫這支的電腦上唯一的一份是 scoop 的 perl 附帶的
# （2026-10-30）。nmake.exe 隨 swiftc 本就需要的 VS C++ 建置工具提供，不增加相依。它經由 vswhere 找到
# 並以 CMAKE_MAKE_PROGRAM 傳入，因此建置腳本不必先載入 vcvars：clang 與 clang-cl 會自行找到 MSVC
# 標頭與函式庫。nmake 不平行建置。NMake 是單一組態，故以 CMAKE_ARCHIVE_OUTPUT_DIRECTORY 把靜態庫放在
# 舊的多組態樹所放之處（<dir>/Release），即 build_libarchive-win.zsh 與 compile_tar-win.zsh 讀取的路徑。

win_clang_cmake() {  # clang|clang-cl <archive-output-dir>
  local driver=$1 out=$2 vswhere vsroot nmake
  (( $+commands[swiftc] )) || { printf '[FAIL] swiftc not on PATH / PATH 上找不到 swiftc\n' >&2; return 1 }
  win_cc=$(cygpath -m "${commands[swiftc]:h}/$driver.exe")
  [[ -x $win_cc ]] || { printf '[FAIL] %s not found / 找不到 Swift 工具鏈的 %s\n' "$win_cc" "$driver" >&2; return 1 }

  vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  [[ -x $vswhere ]] || { printf '[FAIL] vswhere.exe not found; install the VS C++ build tools / 找不到 vswhere.exe\n' >&2; return 1 }
  vsroot=$("$vswhere" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
           -property installationPath | tr -d '\r')
  [[ -n $vsroot ]] || { printf '[FAIL] no VS install with the C++ tools / 沒有含 C++ 工具的 VS 安裝\n' >&2; return 1 }
  nmake=("$(cygpath -u "$vsroot")"/VC/Tools/MSVC/*/bin/Hostx64/x64/nmake.exe(N-.On))
  (( $#nmake )) || { printf '[FAIL] nmake.exe not found under %s / 找不到 nmake.exe\n' "$vsroot" >&2; return 1 }

  win_cmake_args=(-G "NMake Makefiles" -DCMAKE_BUILD_TYPE=Release
                  -DCMAKE_MAKE_PROGRAM="$(cygpath -m "$nmake[1]")"
                  -DCMAKE_C_COMPILER="$win_cc"
                  -DCMAKE_ARCHIVE_OUTPUT_DIRECTORY="$(cygpath -m "$out")")
}
