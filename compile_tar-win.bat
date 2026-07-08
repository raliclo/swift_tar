@echo off
chcp 65001 > nul
:: compile_tar-win.bat -- build swift_tar.exe (multi-core tar archiver) on Windows
::
:: Unlike compile_tar.sh, no C-library linking is needed here: gzip/bzip2/xz/
:: zstd/lz4 shell out to the scoop-installed CLI tools instead (see the
:: #if os(Windows) branches in swift_tar.swift). Only the LZFSE family
:: (other3/bvx3) stays native, reusing lzfse2's lzfse-cli.swift.
:: NOTE: comments in this file are English-only on purpose -- non-ASCII
:: bytes on a comment line were found to corrupt cmd.exe's parsing of
:: subsequent lines in this environment (reproduced independent of chcp).
cd /d "%~dp0"

if not exist ..\lzfse-cli.swift (
    echo [FAIL] ..\lzfse-cli.swift not found / 找不到 ..\lzfse-cli.swift
    pause
    exit /b 1
)

:: Strip the top-level runCLI() entry point (not valid in multi-file builds)
set "_temp_cli=%TEMP%\swift_tar_lzfse_cli-%RANDOM%.swift"
powershell -NoProfile -Command "Get-Content -LiteralPath '..\lzfse-cli.swift' -Encoding UTF8 | Where-Object { $_ -ne 'runCLI()' } | Set-Content -LiteralPath '%_temp_cli%' -Encoding UTF8"
if errorlevel 1 (
    echo [FAIL] failed to strip runCLI^(^) / 剝除 runCLI^(^) 失敗
    pause
    exit /b 1
)

if not exist release mkdir release

set "_build_exe=swift_tar-build-%RANDOM%.exe"
swiftc -O "%_temp_cli%" swift_tar.swift -o "%_build_exe%"
set "_rc=%ERRORLEVEL%"
del /Q "%_temp_cli%" > nul 2>&1
if not "%_rc%"=="0" (
    echo [FAIL] compile failed / 編譯失敗
    pause
    exit /b 1
)

move /Y "%_build_exe%" release\swift_tar.exe > nul
del /Q "%_build_exe:.exe=.lib%" "%_build_exe:.exe=.exp%" > nul 2>&1

echo [OK] Built release\swift_tar.exe / 已建置 release\swift_tar.exe

:: Package a self-contained swift_tar_win.zip (exe + Swift runtime DLLs) so it
:: runs on machines without the Swift toolchain installed. See package_win.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File package_win.ps1 -ExePath release\swift_tar.exe -OutZip release\swift_tar_win.zip
if errorlevel 1 (
    echo [FAIL] packaging swift_tar_win.zip failed / 打包 swift_tar_win.zip 失敗
    pause
    exit /b 1
)
echo [OK] Built release\swift_tar_win.zip / 已建置 release\swift_tar_win.zip
pause
