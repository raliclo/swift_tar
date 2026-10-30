#!/usr/bin/env zsh
#
# build_tool_install-win.zsh -- install the Windows build toolchain for swift_tar
# build_tool_install-win.zsh -- 安裝 swift_tar Windows 版所需的建置工具鏈
#
# Installs, only if missing (safe to re-run):
#   1. Swift toolchain                       (winget: Swift.Toolchain; upgraded if present, then
#                                               user PATH/SDKROOT pointed at the newest install)
#   2. MSVC C++ build tools (link.exe)        (winget: Microsoft.VisualStudio.2022.BuildTools,
#                                               C++ workload -- swiftc needs this to link .exe)
#   3. scoop package manager                  (get.scoop.sh)
#   4. CMake                                  (scoop: cmake; builds static zlib, zstd and
#                                               libarchive with the Swift toolchain's clang)
#   5. Compression CLI tools swift_tar still shells out to on Windows
#                                              (scoop: bzip2 xz zstd lz4 lzip)
#
# After this script succeeds, build the dependencies once, then swift_tar:
#     zsh ./build_zlib-win.zsh
#     zsh ./build_zstd-win.zsh
#     ./compile_tar-win.bat
#
# 只在缺少時才安裝（可重複執行）：
#   1. Swift 工具鏈                           (winget: Swift.Toolchain；已安裝則升級，並把使用者
#                                               PATH／SDKROOT 指向最新安裝)
#   2. MSVC C++ 建置工具（link.exe）           (winget: Microsoft.VisualStudio.2022.BuildTools,
#                                               C++ workload -- swiftc 在 Windows 上連結 .exe 需要)
#   3. scoop 套件管理員                        (get.scoop.sh)
#   4. CMake                                  (scoop: cmake；以 Swift 工具鏈的 clang 建置
#                                               靜態 zlib、zstd、libarchive)
#   5. swift_tar 在 Windows 上仍會 shell out 呼叫的壓縮 CLI 工具
#                                              (scoop: bzip2 xz zstd lz4 lzip)
#
# 完成後先建置一次相依套件，再建置 swift_tar：
#     zsh ./build_zlib-win.zsh
#     zsh ./build_zstd-win.zsh
#     ./compile_tar-win.bat
#
#   zsh ./build_tool_install-win.zsh --help
#       print this synopsis and exit, installing nothing
#       印出本說明後結束，不安裝任何東西
set -e

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '3,40p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

echo "=== swift_tar Windows build toolchain installer ==="

# 1. Swift toolchain -- found by its install directory, then upgraded.
# Not by `command -v swiftc`: on 2026-10-19 Swift went 6.4.0 -> 6.4.1 while a session was open,
# and every shell that session spawned still carried the PATH it inherited at start, naming the
# deleted 6.4.0 bins. swiftc was "not installed" by PATH in a machine that had the newest Swift,
# and the old check would have reinstalled it. The install directory is the fact; PATH is a
# per-process copy of it that can be any age.
# 以安裝目錄判斷，而非 `command -v swiftc`：2026-10-19 Swift 在某 session 開著時由 6.4.0 升到
# 6.4.1，該 session 衍生的每個 shell 仍帶著它啟動時繼承、指向已刪 6.4.0 bin 的 PATH。於是在一台
# 裝著最新 Swift 的機器上，依 PATH 判斷 swiftc「未安裝」，舊的檢查會把它重裝一次。安裝目錄才是
# 事實；PATH 只是每個行程各自持有、年齡不定的副本。
swift_root="$(cygpath -u "${LOCALAPPDATA:-$HOME/AppData/Local}")/Programs/Swift"
# Newest by zsh's numeric glob order, (n), not `sort -V`: an external sort is whichever one PATH
# finds first, and C:\Windows\System32\sort.exe rejects -V (see compile_tar-win.zsh).
# 以 zsh 的數字 glob 排序 (n) 取最新，而非 `sort -V`：外部 sort 是 PATH 先找到的那一個，而
# C:\Windows\System32\sort.exe 不接受 -V（見 compile_tar-win.zsh）。
newest() { local -a f; f=($~1(Nn)); print -r -- "${f[-1]:-}" }
newest_swiftc() { newest "$swift_root/Toolchains/*/usr/bin/swiftc.exe" }
if [[ -n $(newest_swiftc) ]]; then
    printf '[OK] Swift installed: %s\n' "$(newest_swiftc)"
    printf '[UPGRADE] winget upgrade Swift.Toolchain (does nothing if already newest)...\n'
    rc=0
    winget upgrade --id Swift.Toolchain -e \
        --accept-source-agreements --accept-package-agreements || rc=$?
    # winget also exits non-zero when there is nothing to upgrade, and MSYS truncates its 32-bit
    # HRESULT to 8 bits, so the code cannot tell "nothing to do" from a failure. Judge by what is
    # installed afterwards (checked just below) and only report the code.
    # 沒有可升級版本時 winget 也以非 0 結束，而 MSYS 把它的 32 位元 HRESULT 截成 8 位元，退出碼
    # 分不出「無事可做」與失敗。以事後實際安裝的版本判斷（緊接著檢查），退出碼只回報。
    (( rc == 0 )) || printf '[NOTE] winget upgrade exited %s (also what it returns when no upgrade exists); judging by what is installed\n' "$rc"
else
    printf '[INSTALL] Swift toolchain via winget...\n'
    winget install --id Swift.Toolchain -e \
        --accept-source-agreements --accept-package-agreements
fi
swift_tc=$(newest_swiftc)
[[ -n $swift_tc ]] || { printf '[FAIL] no Swift toolchain under %s after install\n' "$swift_root" >&2; exit 1 }
swift_tc=${swift_tc:h}
swift_rt=$(newest "$swift_root/Runtimes/*/usr/bin")
swift_sdk=$(newest "$swift_root/Platforms/*/Windows.platform/Developer/SDKs/Windows.sdk")
# Run it with its own runtime and SDK, not the inherited ones, for the reason above.
# 以它自己的 runtime 與 SDK 執行，而非繼承來的，理由同上。
printf '[OK] newest: %s\n' "$(PATH="$swift_tc:$swift_rt:$PATH" SDKROOT="$(cygpath -w "$swift_sdk")" swiftc --version | head -1)"

# 1b. Persistent environment: drop Swift PATH entries whose directory is gone, make sure the
# newest toolchain and runtime are listed, and point SDKROOT at the newest SDK.
# On 2026-10-19 the installer had in fact rewritten HKCU PATH and SDKROOT to 6.4.1 (what was stale
# was the open session's inherited copy), but it left HKCU's dead 6.3.3 entry behind, and nothing
# guarantees the next upgrade behaves as well. This only writes when something is wrong.
# PATH is written with `reg add`, never `setx`: setx truncates at 1024 characters and this PATH is
# far longer, so it would silently cut it. The value is backed up first, read back after, and
# restored if it does not match. SDKROOT goes through `setx`, which also broadcasts
# WM_SETTINGCHANGE so Explorer -- and so every terminal opened afterwards -- reloads both; the
# value is short, so the truncation cannot reach it. reg and setx take /flags that MSYS would
# rewrite as paths, hence MSYS2_ARG_CONV_EXCL on those calls only.
# 1b. 持久環境：移除目錄已不存在的 Swift PATH 項目，確保列有最新的 toolchain 與 runtime，並把
# SDKROOT 指向最新 SDK。2026-10-19 安裝器其實已把 HKCU 的 PATH 與 SDKROOT 改寫為 6.4.1（過期的是
# 開著的 session 所繼承的副本），但留下了 HKCU 中已失效的 6.3.3 項目，且沒有東西保證下一次升級
# 也一樣乖。本段只在有東西不對時才寫入。PATH 以 `reg add` 寫，絕不用 `setx`：setx 在 1024 字元
# 處截斷，而這條 PATH 遠長於此，會被無聲切掉。寫入前先備份、寫入後讀回、不符即還原。SDKROOT 用
# `setx`，它同時廣播 WM_SETTINGCHANGE，使 Explorer——以及之後開的每個終端機——重新載入兩者；
# 其值很短，截斷碰不到。reg 與 setx 的 /旗標會被 MSYS 改寫成路徑，故僅在這些呼叫上設
# MSYS2_ARG_CONV_EXCL。
# stderr dropped because "value not present" is a normal answer here (reg prints ERROR for it).
# 丟棄 stderr：「值不存在」在此是正常答案（reg 對它印 ERROR）。
reg_value() {  # <key> <name> -> "<type> <value>"
    MSYS2_ARG_CONV_EXCL='*' reg query "$1" /v "$2" 2>/dev/null | tr -d '\r' \
        | sed -nE "s/^ +$2 +(REG_[A-Z_]+) +/\\1 /p"
}
win_norm() { local x=${1%\\}; print -r -- ${x:l} }   # compare paths without case or trailing \
hkcu='HKCU\Environment'

path_entry=$(reg_value "$hkcu" Path)
path_type=${path_entry%% *}
path_raw=${path_entry#* }
kept=() changed=0
for e in "${(@s:;:)path_raw}"; do
    [[ -z $e ]] && continue
    # Only Swift's own literal entries are judged; anything holding %VAR% cannot be tested by
    # cygpath without expansion, so it is kept as is. / 只判斷 Swift 自己的字面路徑；含 %VAR% 的
    # 項目未展開無法以 cygpath 測試，原樣保留。
    if [[ $e == *\\Programs\\Swift\\* && $e != *%* && ! -d $(cygpath -u "$e") ]]; then
        printf '[PRUNE] user PATH: %s (directory gone)\n' "$e"; changed=1; continue
    fi
    kept+=("$e")
done
for want in "$(cygpath -w "$swift_tc")" "$(cygpath -w "$swift_rt")"; do
    found=0
    for e in $kept; do [[ $(win_norm "$e") == $(win_norm "$want") ]] && { found=1; break }; done
    (( found )) || { kept+=("$want"); changed=1; printf '[ADD] user PATH: %s\n' "$want" }
done
if (( changed )); then
    joined=${(j:;:)kept}
    backup_dir="$(cygpath -u "${LOCALAPPDATA:-$HOME/AppData/Local}")/swift_tar"
    backup="$backup_dir/hkcu-path-backup-$(date +%Y%m%d-%H%M%S).txt"
    mkdir -p "$backup_dir"
    printf '%s\n%s\n' "$path_type" "$path_raw" > "$backup"
    MSYS2_ARG_CONV_EXCL='*' reg add "$hkcu" /v Path /t "$path_type" /d "$joined" /f >/dev/null
    readback=$(reg_value "$hkcu" Path); readback=${readback#* }
    if [[ $readback != $joined ]]; then
        MSYS2_ARG_CONV_EXCL='*' reg add "$hkcu" /v Path /t "$path_type" /d "$path_raw" /f >/dev/null
        printf '[FAIL] user PATH did not read back as written; restored the original (backup: %s)\n' "$backup" >&2
        exit 1
    fi
    printf '[OK] user PATH updated (previous value saved to %s)\n' "$backup"
else
    printf '[OK] user PATH already lists the newest Swift and no dead Swift entries\n'
fi

sdk_win=$(cygpath -w "$swift_sdk")
sdk_cur=$(reg_value "$hkcu" SDKROOT); sdk_cur=${sdk_cur#* }
if [[ $(win_norm "$sdk_cur") != $(win_norm "$sdk_win") ]] || (( changed )); then
    MSYS2_ARG_CONV_EXCL='*' setx SDKROOT "$sdk_win" >/dev/null
    printf '[OK] SDKROOT = %s (and settings change broadcast)\n' "$sdk_win"
else
    printf '[OK] SDKROOT already %s\n' "$sdk_cur"
fi

# The system PATH needs an elevated prompt to edit, so dead entries there are only reported:
# a directory that is gone is skipped by every lookup, so leaving them costs nothing.
# 系統 PATH 需提權才能修改，故其中失效項目只回報：已不存在的目錄在每次查找時都會被略過，留著
# 不造成任何影響。
hklm='HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
sys_raw=$(reg_value "$hklm" Path); sys_raw=${sys_raw#* }
for e in "${(@s:;:)sys_raw}"; do
    [[ $e == *\\Programs\\Swift\\* && $e != *%* && ! -d $(cygpath -u "$e") ]] \
        && printf '[NOTE] system PATH has a dead Swift entry (harmless; removing it needs an elevated prompt): %s\n' "$e"
done
printf '[NOTE] Terminals and sessions already open keep the environment they started with; open a new one to see these values.\n'

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

# 4. CMake builds the pinned zlib, zstd and libarchive submodules with the Swift toolchain's
# clang, through nmake from step 2 (see win_clang_cmake.zsh) -- no Ninja needed.
# 4. CMake 以 Swift 工具鏈的 clang、經由步驟 2 的 nmake 建置釘選的 zlib、zstd、libarchive 子模組
# （見 win_clang_cmake.zsh）——不需要 Ninja。
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

echo "=== Done. First run: zsh ./build_zlib-win.zsh; zsh ./build_zstd-win.zsh; then ./compile_tar-win.bat ==="
