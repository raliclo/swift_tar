#!/usr/bin/env zsh
# =====================================================================
# build.zsh -- one entry point; it works out which platform it is on.
# build.zsh -- 單一進入點，自行判斷所處平台。
#
# Before this, the build you ran depended on knowing which script your platform
# used: compile_tar.zsh on macOS, compile_tar-win.bat on Windows, and nothing at
# all on Linux. Nothing in the tree said so. This dispatches on uname and leaves
# the provenance in version-<platform>.txt, so the same command works everywhere
# and the record it writes can never land on another platform's file.
# 在此之前，該執行哪支建置腳本取決於你知不知道自己平台用哪一支：macOS 用
# compile_tar.zsh、Windows 用 compile_tar-win.bat、Linux 則完全沒有。程式庫裡沒有任何
# 地方說明這件事。本腳本依 uname 分派，並將來源資訊寫入 version-<平台>.txt，使同一道
# 指令在各平台皆可用，且其寫下的紀錄絕不會落到另一平台的檔案上。
#
# Usage / 用法:
#   ./build.zsh [args...]      args pass through to the platform's build
#                             參數會原樣傳給該平台的建置腳本
#   ./build.zsh --platform     print the detected platform and exit
#                             印出偵測到的平台後結束
# =====================================================================
set -eu
cd "$(dirname "$0")"
. ./platform.zsh

platform=$(swift_tar_platform)

if [ "${1:-}" = "--platform" ]; then
    echo "$platform"
    exit 0
fi

echo "[Info] platform / 平台: $platform"
echo "[Info] version file / 版本檔: version-$platform.txt"

case "$platform" in
    mac)
        exec ./compile_tar.zsh "$@"
        ;;
    linux)
        exec ./compile_tar-linux.zsh "$@"
        ;;
    win)
        # compile_tar-win.bat needs cmd.exe: it loads the MSVC environment
        # through vcvars64.bat, which only exists as a batch script.
        # compile_tar-win.bat 需要 cmd.exe：它透過只以批次檔形式存在的
        # vcvars64.bat 載入 MSVC 環境。
        if [ $# -gt 0 ]; then
            echo "[Warn] compile_tar-win.bat takes no arguments; ignoring: $*" >&2
            echo "[Warn] compile_tar-win.bat 不接受參數，已忽略：$*" >&2
        fi
        exec cmd.exe //c compile_tar-win.bat
        ;;
    *)
        # Not a stub and not a silent fallback to one of the three: each build
        # script hardcodes its platform's paths and reads linkage back with that
        # platform's tool, so running the wrong one fails somewhere less obvious
        # than this line.
        # 此處既非佔位實作，也不會靜默退回上述三者之一：每支建置腳本都寫死了該平台的
        # 路徑，並以該平台的工具讀回連結資訊，跑錯一支只會在比這一行更難察覺的地方
        # 失敗。
        echo "[Error] no build path for '$platform' / 尚無 '$platform' 的建置路徑" >&2
        echo "        mac → compile_tar.zsh, linux → compile_tar-linux.zsh," >&2
        echo "        win → compile_tar-win.bat" >&2
        exit 1
        ;;
esac
