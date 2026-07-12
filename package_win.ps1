# package_win.ps1 -- package release\swift_tar.exe with the Swift runtime DLLs
# into a self-contained swift_tar_win.zip (runs on machines without Swift installed).
#
# Mirrors helper_windows/build-cli-win.sh's packaging step for lzfse.exe:
# auto-detect the Swift runtime dir from swiftc's own path, copy every DLL in
# it alongside the exe, then zip via Compress-Archive.
#
# gzip is statically linked from the zlib submodule. Other non-LZFSE codecs
# (bzip2/xz/zstd/lz4/lzip) still shell out to external CLI tools on PATH.
# The package includes version.txt and zlib's license, but not the development
# .lib/header/build files because no zlib runtime file is required.
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
if (-not (Test-Path "version.txt")) {
    Write-Error "version.txt not found (run zsh ./build_zlib-win.sh)"
    exit 1
}
if (-not (Test-Path "zlib\LICENSE")) {
    Write-Error "zlib\LICENSE not found (initialize the zlib submodule)"
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
Copy-Item "version.txt" -Destination $stageDir
Copy-Item "zlib\LICENSE" -Destination (Join-Path $stageDir "zlib-LICENSE.txt")

if (Test-Path $OutZip) { Remove-Item -Force $OutZip }
Compress-Archive -Path $stageDir -DestinationPath $OutZip -CompressionLevel Optimal -Force
Remove-Item -Recurse -Force $stageRoot

$dllCount = (Get-ChildItem $rtBin -Filter "*.dll").Count
Write-Host "Packaged: $OutZip (swift_tar.exe + $dllCount Swift runtime DLLs + dependency metadata/licenses)"
