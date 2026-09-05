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
#   ./build.zsh --help         print this synopsis and exit, building nothing
#                             印出本說明後結束，不進行任何建置
# =====================================================================
set -eu

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '3,22p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

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
        # Straight to zsh -- no cmd.exe in the path any more. The Windows build
        # used to run through compile_tar-win.bat, which is now a one-line shim
        # kept only for double-clicking from Explorer; all the logic lives in
        # compile_tar-win.zsh. cmd.exe is still invoked once *inside* that
        # script, to read the MSVC environment out of Microsoft's vcvars64.bat,
        # which exists only as a batch file.
        # 直接交給 zsh——路徑上已不再有 cmd.exe。Windows 建置原本經由
        # compile_tar-win.bat，該檔現已縮為一行 shim，僅供在 Explorer 中按兩下啟動；
        # 所有邏輯位於 compile_tar-win.zsh。cmd.exe 仍會在該腳本「內部」被呼叫一次，
        # 用以自微軟的 vcvars64.bat 讀出 MSVC 環境——該檔僅以批次檔形式存在。
        exec ./compile_tar-win.zsh "$@"
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
