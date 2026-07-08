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

powershell -NoProfile -ExecutionPolicy Bypass -File update_scoop_manifest.ps1 -ZipPath release\swift_tar_win.zip -ManifestPath ..\bucket\swift_tar.json
if errorlevel 1 (
    echo [FAIL] updating ..\bucket\swift_tar.json failed
    pause
    exit /b 1
)

echo [OK] release\swift_tar_win.zip rebuilt and ..\bucket\swift_tar.json refreshed
pause
