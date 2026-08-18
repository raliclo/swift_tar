#!/usr/bin/env zsh
# package_win.zsh -- package release/swift_tar.exe with the Swift runtime DLLs
# into a self-contained swift_tar_win.zip (runs on machines without Swift).
# package_win.zsh -- 將 release/swift_tar.exe 與 Swift runtime DLL 一併封裝為
# 自帶執行環境的 swift_tar_win.zip（可在未安裝 Swift 的機器上執行）。
#
#   ./package_win.zsh --exe release/swift_tar.exe --out release/swift_tar_win.zip
#   ./package_win.zsh --help
#
# Mirrors helper_windows/build-cli-win.zsh's packaging step for lzfse.exe: find
# the Swift runtime directory from swiftc's own location, copy every DLL beside
# the exe, then zip.
# 與 helper_windows/build-cli-win.zsh 為 lzfse.exe 所做的封裝步驟一致：由 swiftc
# 自身位置推得 Swift runtime 目錄，將其中所有 DLL 複製到 exe 旁，再打包成 zip。
#
# gzip, zstd and the ZIP backend are statically linked from the zlib, zstd and
# libarchive submodules. The other non-LZFSE codecs (bzip2/xz/lz4/lzip) still
# shell out to CLI tools on PATH. The package carries version-win.txt staged as
# version.txt plus the three dependency licenses, and no development files,
# because nothing else is needed at run time.
# gzip、zstd 與 ZIP 後端皆自 zlib、zstd、libarchive submodule 靜態連結。其餘非
# LZFSE 的壓縮引擎（bzip2/xz/lz4/lzip）仍呼叫 PATH 上的外部 CLI。套件內含以
# version.txt 為名放入的 version-win.txt 與三份相依授權檔，不含開發用檔案，因為
# 執行期不需要它們。
#
# Zips with the Windows-bundled bsdtar rather than PowerShell's
# Compress-Archive: the user-level scripting policy reserves PowerShell for UAC
# elevation shims, and bsdtar is present on every supported Windows build.
# 使用 Windows 內建的 bsdtar 而非 PowerShell 的 Compress-Archive 打包：使用者層級
# 的腳本政策僅保留 PowerShell 作為 UAC 提權 shim，而 bsdtar 在所有受支援的 Windows
# 版本上皆已內建。
set -euo pipefail

script_path="${0:A}"

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,12p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

exe="release/swift_tar.exe"
out="release/swift_tar_win.zip"
while (( $# )); do
  case $1 in
    --exe) exe=${2:?--exe needs a path}; shift 2 ;;
    --out) out=${2:?--out needs a path}; shift 2 ;;
    *) print -ru2 -- "unknown option: $1 (try --help)"; exit 1 ;;
  esac
done

die() { print -ru2 -- "package_win: $1"; exit 1 }

[[ -f $exe ]]                 || die "not found: $exe (build it first, e.g. via compile_tar-win.bat)"
[[ -f version-win.txt ]]      || die "version-win.txt not found (run zsh ./build_zlib-win.zsh)"
[[ -f zlib/LICENSE ]]         || die "zlib/LICENSE not found (initialize the zlib submodule)"
[[ -f zstd/LICENSE ]]         || die "zstd/LICENSE not found (initialize the zstd submodule)"
[[ -f libarchive/COPYING ]]   || die "libarchive/COPYING not found (initialize the libarchive submodule)"

(( $+commands[swiftc] )) || die "swiftc not found on PATH"
# swiftc lives at .../Programs/Swift/Toolchains/<ver>/usr/bin/swiftc.exe, so the
# Swift root is five levels up.
# swiftc 位於 .../Programs/Swift/Toolchains/<ver>/usr/bin/swiftc.exe，故 Swift
# 根目錄在其上五層。
swift_root=${${commands[swiftc]}:A:h:h:h:h:h}
rt_dll=( ${swift_root}/Runtimes/**/swiftCore.dll(N) )
(( $#rt_dll )) || die "Swift runtime (swiftCore.dll) not found under $swift_root/Runtimes"
rt_bin=${rt_dll[1]:h}
print -r -- "Swift runtime: $rt_bin"

stage_root=${out:h}/swift_tar_win_stage
stage_dir=$stage_root/swift_tar-win
rm -rf $stage_root
mkdir -p $stage_dir

cp $exe $stage_dir/
cp $rt_bin/*.dll $stage_dir/
# Staged under the plain name: inside a Windows-only package the suffix would be
# noise, and the packaged layout stays as documented.
# 以無後綴的名稱放入：在僅含 Windows 的套件內，後綴只是雜訊，且套件版面維持與文件
# 所述一致。
cp version-win.txt      $stage_dir/version.txt
cp zlib/LICENSE         $stage_dir/zlib-LICENSE.txt
cp zstd/LICENSE         $stage_dir/zstd-LICENSE.txt
cp libarchive/COPYING   $stage_dir/libarchive-COPYING.txt

bsdtar=${BSDTAR_BIN:-/c/Windows/System32/tar.exe}
[[ -x $bsdtar ]] || die "bsdtar not found at $bsdtar (set BSDTAR_BIN)"

rm -f $out
# Resolve the output to an absolute path BEFORE the subshell cds away. `:A` is
# evaluated where it appears, so writing ${out:A} inside the subshell resolves
# it against the stage directory instead -- bsdtar then reported
# "Failed to open .../swift_tar_win_stage/release/swift_tar_win.zip".
# 在 subshell 切換目錄「之前」先解出輸出的絕對路徑。`:A` 於出現處求值，若寫在
# subshell 內會改以暫存目錄為基準——bsdtar 當時即回報
# 「Failed to open .../swift_tar_win_stage/release/swift_tar_win.zip」。
out_abs=${out:A}
# cd into the stage root so the archive holds swift_tar-win/... rather than the
# whole staging path.
# 切換至暫存根目錄，使封存內是 swift_tar-win/… 而非整條暫存路徑。
( cd $stage_root && $bsdtar --format zip -cf $out_abs swift_tar-win )
[[ -s $out ]] || die "packaging produced no archive"

rm -rf $stage_root
dll_count=${#$(print -l $rt_bin/*.dll(N))}
print -r -- "Packaged: $out (swift_tar.exe + $dll_count Swift runtime DLLs + dependency metadata/licenses)"
