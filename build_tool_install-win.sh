#!/usr/bin/env zsh
#
# build_tool_install-win.sh -- install the Windows build toolchain for swift_tar
# build_tool_install-win.sh -- 安裝 swift_tar Windows 版所需的建置工具鏈
#
# Installs, only if missing (safe to re-run):
#   1. Swift toolchain                       (winget: Swift.Toolchain)
#   2. MSVC C++ build tools (link.exe)        (winget: Microsoft.VisualStudio.2022.BuildTools,
#                                               C++ workload -- swiftc needs this to link .exe)
#   3. scoop package manager                  (get.scoop.sh)
#   4. CMake                                  (scoop: cmake; builds static zlib)
#   5. Compression CLI tools swift_tar still shells out to on Windows
#                                              (scoop: bzip2 xz zstd lz4 lzip)
#
# After this script succeeds, build the dependencies once, then swift_tar:
#     zsh ./build_zlib-win.sh
#     zsh ./build_zstd-win.sh
#     ./compile_tar-win.bat
#
# 只在缺少時才安裝（可重複執行）：
#   1. Swift 工具鏈                           (winget: Swift.Toolchain)
#   2. MSVC C++ 建置工具（link.exe）           (winget: Microsoft.VisualStudio.2022.BuildTools,
#                                               C++ workload -- swiftc 在 Windows 上連結 .exe 需要)
#   3. scoop 套件管理員                        (get.scoop.sh)
#   4. CMake                                  (scoop: cmake；建置靜態 zlib)
#   5. swift_tar 在 Windows 上仍會 shell out 呼叫的壓縮 CLI 工具
#                                              (scoop: bzip2 xz zstd lz4 lzip)
#
# 完成後先建置一次相依套件，再建置 swift_tar：
#     zsh ./build_zlib-win.sh
#     zsh ./build_zstd-win.sh
#     ./compile_tar-win.bat
set -e

echo "=== swift_tar Windows build toolchain installer ==="

# 1. Swift toolchain
if command -v swiftc >/dev/null 2>&1; then
    echo "[OK] swiftc already installed: $(swiftc --version 2>&1 | head -1)"
else
    echo "[INSTALL] Swift toolchain via winget..."
    winget install --id Swift.Toolchain -e \
        --accept-source-agreements --accept-package-agreements
fi

# 2. MSVC C++ build tools (link.exe). Checked via vswhere, not PATH: MSYS/scoop
# ship an unrelated coreutils `link.exe` (POSIX link(2) wrapper) that would
# otherwise produce a false "already installed" positive.
# 用 vswhere 檢查，不查 PATH：MSYS/scoop 的 `link.exe` 是 coreutils 的
# link(2) wrapper，跟 MSVC 連結器無關，查 PATH 會誤判成「已安裝」。
VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
HAS_VC_TOOLS=""
if [ -f "$VSWHERE" ]; then
    HAS_VC_TOOLS="$("$VSWHERE" -latest -products '*' \
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
        -property installationPath 2>/dev/null)"
fi
if [ -n "$HAS_VC_TOOLS" ]; then
    echo "[OK] MSVC C++ build tools already installed: $HAS_VC_TOOLS"
else
    echo "[INSTALL] Visual Studio Build Tools (C++ workload) via winget..."
    winget install --id Microsoft.VisualStudio.2022.BuildTools -e \
        --accept-source-agreements --accept-package-agreements \
        --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
fi

# 3. scoop package manager
if command -v scoop >/dev/null 2>&1; then
    echo "[OK] scoop already installed"
else
    echo "[INSTALL] scoop..."
    powershell -NoProfile -Command \
        "Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force; Invoke-RestMethod get.scoop.sh | Invoke-Expression"
fi

# 4. CMake builds the pinned zlib submodule as a static MSVC library.
if command -v cmake >/dev/null 2>&1; then
    echo "[OK] cmake already installed: $(cmake --version | head -1)"
else
    echo "[INSTALL] cmake via scoop..."
    scoop install cmake
fi

# 5. Compression CLI tools (see the #if os(Windows) branches in swift_tar.swift).
# Checked via `scoop list <name>`, not PATH: some of these names also resolve
# to limited busybox applets (e.g. a decompress-only `xz`) bundled with other
# packages, which would produce a false "already installed" positive too.
# 用 `scoop list <name>` 檢查，不查 PATH：同名指令有時會解析到其他套件附帶
# 的閹割版 busybox applet（例如只能解壓的 `xz`），查 PATH 一樣會誤判。
for tool in bzip2 xz zstd lz4 lzip; do
    if scoop list "$tool" 2>/dev/null | grep -qE "^${tool}[[:space:]]"; then
        echo "[OK] $tool already installed (scoop)"
    else
        echo "[INSTALL] $tool via scoop..."
        scoop install "$tool"
    fi
done

echo "=== Done. First run: zsh ./build_zlib-win.sh; zsh ./build_zstd-win.sh; then ./compile_tar-win.bat ==="
