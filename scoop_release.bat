@echo off
chcp 65001 > nul
:: scoop_release.bat -- rebuild swift_tar_win.zip and refresh bucket\swift_tar.json's hash
:: NOTE: comments in this file are English-only on purpose -- non-ASCII
:: bytes on a comment line were found to corrupt cmd.exe's parsing of
:: subsequent lines in this environment (reproduced independent of chcp).
cd /d "%~dp0"

call .\compile_tar-win.bat
if errorlevel 1 (
    echo [FAIL] compile_tar-win.bat failed / release/swift_tar_win.zip was not rebuilt
    exit /b 1
)

:: Publish the zip as a GitHub Release asset. The manifest points at the release
:: download URL, so the asset has to exist before the manifest is installable.
:: Build output stays untracked, which is why the zip is distributed this way
:: instead of being committed.
:: The tag is derived from the manifest's own version field, so the release the
:: manifest points at and the release this script publishes cannot drift apart.
:: Bump the version in the manifest only.
set "_repo=raliclo/swift_tar"
set "_manifest=..\bucket\swift_tar.json"
set "_version="
for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "(ConvertFrom-Json (Get-Content -Raw -LiteralPath '%_manifest%')).version"`) do set "_version=%%V"
if not defined _version (
    echo [FAIL] could not read the version field from %_manifest%
    pause
    exit /b 1
)
set "_tag=v%_version%"
echo [INFO] manifest version %_version% -- targeting release %_tag%

where gh > nul 2>&1
if errorlevel 1 (
    echo [FAIL] gh CLI not found -- install it, or upload release\swift_tar_win.zip manually
    pause
    exit /b 1
)

gh release view %_tag% --repo %_repo% > nul 2>&1
if not errorlevel 1 goto :haveRelease
echo [INFO] creating release %_tag% on %_repo%
gh release create %_tag% --repo %_repo% --title %_tag% --notes "scoop release"
if errorlevel 1 (
    echo [FAIL] could not create release %_tag% on %_repo%
    pause
    exit /b 1
)
:haveRelease

gh release upload %_tag% release\swift_tar_win.zip --repo %_repo% --clobber
if errorlevel 1 (
    echo [FAIL] uploading swift_tar_win.zip to %_tag% failed
    pause
    exit /b 1
)

zsh .\update_scoop_manifest.zsh --zip release\swift_tar_win.zip --manifest %_manifest%
if errorlevel 1 (
    echo [FAIL] updating %_manifest% failed
    pause
    exit /b 1
)

echo [OK] release\swift_tar_win.zip rebuilt, uploaded to %_tag%, and %_manifest% refreshed
pause
