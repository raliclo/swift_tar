#!/usr/bin/env zsh
# compile_tar-win.zsh -- build swift_tar.exe (multi-core tar archiver) on Windows.
# compile_tar-win.zsh -- 在 Windows 上建置 swift_tar.exe（多核心 tar 封存工具）。
#
#   ./compile_tar-win.zsh          # or: zsh ./build.zsh, which dispatches here
#   ./compile_tar-win.zsh --help
#
# gzip links the zlib submodule statically and zstd links the zstd submodule
# statically; bzip2/xz/lz4 still shell out to scoop-installed CLI tools. The
# LZFSE family stays native, reusing lzfse2's lzfse-cli.swift.
# gzip 靜態連結 zlib submodule，zstd 靜態連結 zstd submodule；bzip2／xz／lz4 仍呼叫
# scoop 安裝的外部 CLI。LZFSE 家族維持原生，沿用 lzfse2 的 lzfse-cli.swift。
#
# This replaces compile_tar-win.bat, which is now a one-line shim. All the logic
# lives here, which removes two whole classes of problem the batch file had:
#   - cmd.exe mis-parses an LF-only .bat that contains non-ASCII bytes, so the
#     bilingual original was pinned to CRLF while everything else moved to LF.
#     A one-line ASCII shim has neither constraint.
#   - the install step was PowerShell, purely to retry a locked move. zsh does
#     that in four lines, so the build no longer invokes PowerShell at all.
# 本檔取代 compile_tar-win.bat，後者現已縮為一行 shim。所有邏輯集中於此，並藉此消除
# 批次檔原有的兩整類問題：
#   - cmd.exe 會誤解析「僅用 LF 且含非 ASCII 位元組」的 .bat，故雙語的原檔被迫維持
#     CRLF，而其餘檔案皆已改用 LF。一行的純 ASCII shim 兩個限制都沒有。
#   - 安裝步驟原本使用 PowerShell，只為了重試一個被鎖住的搬移。zsh 四行即可完成，
#     因此建置流程已完全不再呼叫 PowerShell。
#
# cmd.exe is still called exactly once, to harvest the MSVC environment from
# vcvars64.bat. That file is Microsoft's and only exists as a batch script, so
# the variables it sets have to be read out of a cmd process; nothing else runs
# there.
# cmd.exe 仍會被呼叫「恰好一次」，用以自 vcvars64.bat 擷取 MSVC 環境。該檔屬微軟且
# 僅以批次檔形式存在，故其設定的變數必須自 cmd 行程中讀出；除此之外沒有任何東西在
# 那裡執行。
set -euo pipefail

script_path="${0:A}"

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,12p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

cd "${script_path:h}"

die() { print -ru2 -- "[FAIL] $1"; exit 1 }
note() { print -r -- "$1" }

# ---- MSVC environment / MSVC 環境 ----
if ! (( $+commands[cl] )); then
    vswhere='/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe'
    [[ -x $vswhere ]] || die "vswhere.exe not found. Run: zsh ./build_tool_install-win.zsh"

    vsroot=$("$vswhere" -latest -products '*' \
                 -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
                 -property installationPath 2>/dev/null | head -1)
    vsroot=${vsroot%$'\r'}
    [[ -n $vsroot ]] || die "MSVC C++ tools not found. Run: zsh ./build_tool_install-win.zsh"

    # vsroot comes back as a Windows path; reach it through /<drive>/ so zsh can
    # test it. / vsroot 回傳的是 Windows 路徑，改以 /<drive>/ 形式存取，zsh 才能檢查。
    vsroot_posix="/${vsroot[1]:l}/${${vsroot:3}//\\//}"
    vcvars_dir="$vsroot_posix/VC/Auxiliary/Build"
    [[ -f $vcvars_dir/vcvars64.bat ]] || die "vcvars64.bat not found under $vsroot"

    # Harvest the environment rather than trying to reproduce it. Three details
    # here were each a failure on the way:
    #   - cd into the directory first: cmd.exe does NOT search the current
    #     directory, and a quoted path containing spaces gets rewritten by the
    #     MSYS argument conversion before cmd ever sees it.
    #   - `.\` prefix for the same reason -- a bare name is "not recognized".
    #   - `//c`, not `/c`: the runtime rewrites a lone /c into a drive path, and
    #     MSYS2_ARG_CONV_EXCL='*' does not help because it stops //c collapsing
    #     to /c as well. Both mistakes end the same way: cmd opens an
    #     interactive shell and prints its banner, which looks nothing like a
    #     mangled flag.
    # 擷取環境，而非試圖自行重建它。以下三個細節在過程中各自失敗過一次：
    #   - 先 cd 進該目錄：cmd.exe「不會」搜尋目前目錄，且含空白的引號路徑會在 cmd
    #     看到之前就被 MSYS 引數轉換改寫。
    #   - 同理需要 `.\` 前綴——裸檔名會得到 "not recognized"。
    #   - 要用 `//c` 而非 `/c`：runtime 會把單獨的 /c 改寫成磁碟路徑，而
    #     MSYS2_ARG_CONV_EXCL='*' 幫不上忙，因為它同時也阻止了 //c 收斂為 /c。
    #     兩種錯誤的結局相同：cmd 開出互動 shell 並印出橫幅，看起來完全不像旗標被改寫。
    note "[Info] loading MSVC x64 environment / 載入 MSVC x64 環境"
    vcenv=$(cd "$vcvars_dir" && cmd //c "call .\\vcvars64.bat >nul 2>&1 && set" </dev/null 2>/dev/null) \
        || die "failed to load MSVC x64 build environment"

    # Match the names case-insensitively. cmd's `set` prints the PATH variable
    # with whatever casing the process happens to hold -- observed as `PATH`
    # here, but `Path` is just as common, and a case-sensitive lookup silently
    # skipped it: every other variable imported fine and the build failed later
    # with "cl.exe still not on PATH", which points at vcvars rather than at the
    # parser that dropped one line.
    # 名稱比對不分大小寫。cmd 的 `set` 會以行程當下持有的大小寫印出 PATH 變數——此處
    # 觀察到的是 `PATH`，但 `Path` 同樣常見，而區分大小寫的查找會無聲地跳過它：其餘
    # 變數都正常匯入，建置卻在稍後以「cl.exe still not on PATH」失敗，該訊息指向的是
    # vcvars，而非那個漏掉一行的解析器。
    while IFS= read -r line; do
        line=${line%$'\r'}
        name=${line%%=*}
        value=${line#*=}
        case ${name:u} in
            INCLUDE|LIB|LIBPATH|PATH) ;;
            *) continue ;;
        esac
        if [[ ${name:u} == PATH ]]; then
            # Convert the Windows PATH to POSIX form and prepend it, keeping the
            # existing PATH so zsh, git and the scoop tools stay reachable.
            # 將 Windows PATH 轉為 POSIX 形式並前置，同時保留原有 PATH，使 zsh、git
            # 與 scoop 工具仍可取用。
            converted=""
            for part in ${(s.;.)value}; do
                [[ -n $part ]] || continue
                [[ $part == [A-Za-z]:* ]] && part="/${part[1]:l}/${${part:3}//\\//}"
                converted="$converted:$part"
            done
            export PATH="${converted#:}:$PATH"
        else
            export ${name:u}="$value"
        fi
    done <<< "$vcenv"

    (( $+commands[cl] )) || die "cl.exe still not on PATH after loading vcvars64"
fi

# ---- preconditions / 前置條件 ----
# LZFSE 引擎的來源，以及「不含它」這個選項。
#
# 路徑要找兩個地方。`../lzfse-cli.swift` 是 swift_tar 還住在 lzfse2 底下那個年代留下的
# 寫法；如今 lzfse2 是 swift_tar 的 submodule，檔案在 lzfse2/lzfse-cli.swift，而 `../`
# 指向 repo 之外——在目前的配置下它一定不存在，於是這支腳本在做任何事之前就 die。舊路徑
# 保留為後備，因為那個舊配置在別處可能仍然成立。
#
# EXCLUDE_LZFSE=1 則完全不需要它：那是公開／可散布版，也是 test_no_lzfse 用來對照的另一
# 半。此環境覆寫刻意與 compile_tar-linux.zsh 的同名覆寫同名同義，好讓該測試對兩個平台
# 用同一種寫法提出同一個要求。
#
# Where the LZFSE engine comes from, and how to ask for a build without it.
#
# Two locations are tried. `../lzfse-cli.swift` dates from when swift_tar lived
# inside lzfse2; today lzfse2 is swift_tar's own submodule and the file is at
# lzfse2/lzfse-cli.swift, while `../` points outside the repository -- so under
# the current layout it cannot exist and this script died before doing anything.
# The old path stays as a fallback, since that older layout may still hold
# elsewhere.
#
# EXCLUDE_LZFSE=1 needs neither: that is the public/distributable build, and the
# other half of the contrast test_no_lzfse draws. The override deliberately
# carries the same name and meaning as the one in compile_tar-linux.zsh, so that
# test can ask both platforms for the same thing in the same words.
LZFSE_CLI=""
if [[ -n ${EXCLUDE_LZFSE:-} && ${EXCLUDE_LZFSE} != 0 ]]; then
  note "EXCLUDE_LZFSE set; building without the LZFSE engine / 已設定，不含 LZFSE 引擎"
else
  for candidate in lzfse2/lzfse-cli.swift ../lzfse-cli.swift; do
    [[ -f $candidate ]] && { LZFSE_CLI=$candidate; break }
  done
  [[ -n $LZFSE_CLI ]] || die "lzfse-cli.swift not found in lzfse2/ or ../ ; run: git submodule update --init lzfse2 / 在 lzfse2/ 與 ../ 均找不到 lzfse-cli.swift"
fi
[[ -f zlib/build/Release/zs.lib ]]            || die "zlib static library not found. Run: zsh ./build_zlib-win.zsh"
[[ -f build/zstd-win/lib/Release/zstd_static.lib ]] || die "zstd static library not found. Run: zsh ./build_zstd-win.zsh"
[[ -f version-win.txt ]]                      || die "version-win.txt not found. Run: zsh ./build_zlib-win.zsh"

# ---- libarchive backend / libarchive 後端 ----
zsh ./build_libarchive-win.zsh || die "libarchive backend build failed / libarchive 後端建置失敗"

mkdir -p build
# Dash-form MSVC flags, not the slash form. The MSYS runtime rewrites a
# `/`-prefixed argument into a Windows path before cl ever sees it, so `/nologo`
# arrived as `C:/Users/.../scoop/apps/zsh/<version>/nologo` and cl reported
# "unrecognized source file type" for every flag in turn. cl has always accepted
# `-nologo`, `-O2` and the rest, so using them sidesteps the conversion entirely
# -- better than MSYS2_ARG_CONV_EXCL, which is all-or-nothing per invocation and
# would also stop the source and output paths being converted, which they need.
# 使用 MSVC 的 dash 形式旗標，而非斜線形式。MSYS runtime 會在 cl 看到之前，就把以
# `/` 開頭的引數改寫為 Windows 路徑，故 `/nologo` 抵達時已變成
# `C:/Users/.../scoop/apps/zsh/<version>/nologo`，cl 遂對每一個旗標依序回報
# 「unrecognized source file type」。cl 向來接受 `-nologo`、`-O2` 等寫法，改用它們
# 即可完全繞開該轉換——這比 MSYS2_ARG_CONV_EXCL 更好，後者對單次呼叫是全有全無，
# 會連帶阻止原始檔與輸出路徑的轉換，而那兩者正需要被轉換。
cl -nologo -O2 -MD -utf-8 -DLIBARCHIVE_STATIC -c libarchive_zip_bridge.c \
   -Ilibarchive/libarchive -Fobuild/libarchive_zip_bridge.obj \
   || die "libarchive bridge compile failed / libarchive bridge 編譯失敗"

# ---- sources / 原始碼 ----
# Strip the top-level runCLI() entry point: it is not valid in a multi-file build.
# 剝除頂層的 runCLI() 進入點：多檔建置中它並不合法。
tmp_cli=$(mktemp -u)_cli.swift
tmp_version=$(mktemp -u)_version.swift
cleanup() { rm -f "$tmp_cli" "$tmp_version" }
trap cleanup EXIT

# 排除 LZFSE 時不剝除、也不納入 lzfse-cli.swift，改以 -DEXCLUDE_LZFSE 編譯——與
# compile_tar-linux.zsh 的作法一致。zsh 中空陣列的 "${arr[@]}" 展開為零個字，因此同一行
# swiftc 兩種情況都適用，不需要複製一份。
# When LZFSE is excluded, lzfse-cli.swift is neither stripped nor compiled in and
# -DEXCLUDE_LZFSE is passed instead, matching compile_tar-linux.zsh. In zsh
# "${arr[@]}" on an empty array expands to zero words, so one swiftc line serves
# both cases and no copy of it is needed.
SWIFT_DEFINES=()
CLI_SRC=()
if [[ -n $LZFSE_CLI ]]; then
  zsh ./strip_runcli.zsh "$LZFSE_CLI" "$tmp_cli" || die "failed to strip runCLI() / 剝除 runCLI() 失敗"
  CLI_SRC=("$tmp_cli")
else
  SWIFT_DEFINES=(-DEXCLUDE_LZFSE)
fi
zsh ./generate_version.zsh "$tmp_version"           || die "build version generation failed"

# ---- link / 連結 ----
mkdir -p release
build_exe="swift_tar-build-$$.exe"
swiftc -O "${SWIFT_DEFINES[@]}" "${CLI_SRC[@]}" "$tmp_version" swift_tar.swift rgb1.swift crypto.swift \
       build/libarchive_zip_bridge.obj \
       build/libarchive-win/libarchive/Release/archive.lib \
       -o "$build_exe" \
       -I cmodules/zlib -Xcc -Izlib -Xcc -Izlib/build \
       -Lzlib/build/Release -lzs \
       -Lbuild/zstd-win/lib/Release -lzstd_static \
    || die "compile failed / 編譯失敗"

# ---- install, with retry / 安裝，含重試 ----
# release/swift_tar.exe can be transiently locked -- an antivirus real-time scan,
# or a previous test run's process still releasing its handle -- so a plain move
# fails with "Access is denied". The batch version shelled out to PowerShell for
# this loop; it is four lines of zsh. The original bug worth remembering is not
# the lock but that move's exit code was never checked, so the build left the OLD
# exe in place and still printed [OK].
# release/swift_tar.exe 可能短暫被鎖住——防毒即時掃描，或前一次測試的行程尚未釋放
# handle——因而單純的搬移會以「拒絕存取」失敗。批次版為此呼叫 PowerShell 跑這個迴圈；
# 用 zsh 只需四行。真正值得記住的原始缺陷不是鎖，而是當初從未檢查 move 的離開碼，
# 導致建置留著「舊的」exe 卻仍印出 [OK]。
installed=0
for attempt in {1..10}; do
    if mv -f "$build_exe" release/swift_tar.exe 2>/dev/null; then installed=1; break; fi
    note "install retry $attempt"
    sleep 0.5
done
(( installed )) || die "could not install release/swift_tar.exe after retries / 重試多次後仍無法安裝"
rm -f "${build_exe%.exe}.lib" "${build_exe%.exe}.exp"

note "[OK] Built release/swift_tar.exe / 已建置 release/swift_tar.exe"

# ---- package / 打包 ----
zsh ./package_win.zsh --exe release/swift_tar.exe --out release/swift_tar_win.zip \
    || die "packaging swift_tar_win.zip failed / 打包 swift_tar_win.zip 失敗"
note "[OK] Built release/swift_tar_win.zip / 已建置 release/swift_tar_win.zip"
