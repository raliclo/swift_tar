# package_win.ps1 -- package release\swift_tar.exe with the Swift runtime DLLs
# into a self-contained swift_tar_win.zip (runs on machines without Swift installed).
#
# Mirrors helper_windows/build-cli-win.sh's packaging step for lzfse.exe:
# auto-detect the Swift runtime dir from swiftc's own path, copy every DLL in
# it alongside the exe, then zip via Compress-Archive.
#
# gzip, zstd, and the ZIP backend are statically linked from the zlib, zstd,
# and libarchive submodules. Other
# non-LZFSE codecs (bzip2/xz/lz4/lzip) still shell out to external CLI tools on
# PATH. The package includes version-win.txt, staged as version.txt, and the
# zlib + zstd + libarchive
# licenses, but not development .lib/header/build files because no runtime
# file is required.
#
# Usage: powershell -File package_win.ps1 -ExePath release\swift_tar.exe -OutZip release\swift_tar_win.zip

param(
    [Parameter(Mandatory=$true)][string]$ExePath,
    [Parameter(Mandatory=$true)][string]$OutZip
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ExePath)) {
    Write-Error "Not found: $ExePath (build it first, e.g. via compile_tar-win.bat)"
    exit 1
}
if (-not (Test-Path "version-win.txt")) {
    Write-Error "version-win.txt not found (run zsh ./build_zlib-win.sh)"
    exit 1
}
if (-not (Test-Path "zlib\LICENSE")) {
    Write-Error "zlib\LICENSE not found (initialize the zlib submodule)"
    exit 1
}
if (-not (Test-Path "zstd\LICENSE")) {
    Write-Error "zstd\LICENSE not found (initialize the zstd submodule)"
    exit 1
}
if (-not (Test-Path "libarchive\COPYING")) {
    Write-Error "libarchive\COPYING not found (initialize the libarchive submodule)"
    exit 1
}

$swiftc = (Get-Command swiftc -ErrorAction SilentlyContinue).Source
if (-not $swiftc) {
    Write-Error "swiftc not found on PATH"
    exit 1
}
# swiftc lives at .../Programs/Swift/Toolchains/<ver>/usr/bin/swiftc.exe
$swiftRoot = Split-Path (Split-Path (Split-Path (Split-Path (Split-Path $swiftc))))
$rtDll = Get-ChildItem -Path (Join-Path $swiftRoot "Runtimes") -Filter "swiftCore.dll" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $rtDll) {
    Write-Error "Swift runtime (swiftCore.dll) not found under $swiftRoot\Runtimes"
    exit 1
}
$rtBin = $rtDll.DirectoryName
Write-Host "Swift runtime: $rtBin"

$stageRoot = Join-Path (Split-Path $OutZip) "swift_tar_win_stage"
$stageDir = Join-Path $stageRoot "swift_tar-win"
if (Test-Path $stageRoot) { Remove-Item -Recurse -Force $stageRoot }
New-Item -ItemType Directory -Path $stageDir | Out-Null
Copy-Item $ExePath -Destination $stageDir
Copy-Item (Join-Path $rtBin "*.dll") -Destination $stageDir
# Staged under the plain name: inside a Windows-only package the suffix would
# be noise, and the packaged layout stays as documented.
# 以無後綴的名稱放入：在僅含 Windows 的套件內，後綴只是雜訊，且套件版面維持與文件
# 所述一致。
Copy-Item "version-win.txt" -Destination (Join-Path $stageDir "version.txt")
Copy-Item "zlib\LICENSE" -Destination (Join-Path $stageDir "zlib-LICENSE.txt")
Copy-Item "zstd\LICENSE" -Destination (Join-Path $stageDir "zstd-LICENSE.txt")
Copy-Item "libarchive\COPYING" -Destination (Join-Path $stageDir "libarchive-COPYING.txt")

if (Test-Path $OutZip) { Remove-Item -Force $OutZip }
Compress-Archive -Path $stageDir -DestinationPath $OutZip -CompressionLevel Optimal -Force
Remove-Item -Recurse -Force $stageRoot

$dllCount = (Get-ChildItem $rtBin -Filter "*.dll").Count
Write-Host "Packaged: $OutZip (swift_tar.exe + $dllCount Swift runtime DLLs + dependency metadata/licenses)"
