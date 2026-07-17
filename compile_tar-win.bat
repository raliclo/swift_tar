@echo off
chcp 65001 > nul
:: compile_tar-win.bat -- build swift_tar.exe (multi-core tar archiver) on Windows
::
:: gzip links the zlib submodule statically; zstd links the zstd submodule statically. bzip2/xz/lz4 still shell out
:: to scoop-installed CLI tools. The LZFSE family stays native, reusing
:: lzfse2's lzfse-cli.swift.
:: NOTE: comments in this file are English-only on purpose -- non-ASCII
:: bytes on a comment line were found to corrupt cmd.exe's parsing of
:: subsequent lines in this environment (reproduced independent of chcp).
cd /d "%~dp0"

if not exist ..\lzfse-cli.swift (
    echo [FAIL] ..\lzfse-cli.swift not found / 找不到 ..\lzfse-cli.swift
    pause
    exit /b 1
)

if not exist zlib\build\Release\zs.lib (
    echo [FAIL] zlib static library not found. Run: zsh ./build_zlib-win.sh
    pause
    exit /b 1
)
if not exist zstd\build\lib\Release\zstd_static.lib (
    echo [FAIL] zstd static library not found. Run: zsh ./build_zstd-win.sh
    pause
    exit /b 1
)
if not exist version.txt (
    echo [FAIL] version.txt not found. Run: zsh ./build_zlib-win.sh
    pause
    exit /b 1
)

:: Strip the top-level runCLI() entry point (not valid in multi-file builds)
set "_temp_cli=%TEMP%\swift_tar_lzfse_cli-%RANDOM%.swift"
set "_temp_version=%TEMP%\swift_tar_version-%RANDOM%.swift"
powershell -NoProfile -Command "Get-Content -LiteralPath '..\lzfse-cli.swift' -Encoding UTF8 | Where-Object { $_ -ne 'runCLI()' } | Set-Content -LiteralPath '%_temp_cli%' -Encoding UTF8"
if errorlevel 1 (
    echo [FAIL] failed to strip runCLI^(^) / 剝除 runCLI^(^) 失敗
    pause
    exit /b 1
)
zsh .\generate_version.sh "%_temp_version%"
if errorlevel 1 (
    echo [FAIL] build version generation failed
    del /Q "%_temp_cli%" > nul 2>&1
    pause
    exit /b 1
)

if not exist release mkdir release

set "_build_exe=swift_tar-build-%RANDOM%.exe"
swiftc -O "%_temp_cli%" "%_temp_version%" swift_tar.swift -o "%_build_exe%" -I cmodules\zlib -Xcc -Izlib -Xcc -Izlib\build -Lzlib\build\Release -lzs -Lzstd\build\lib\Release -lzstd_static
set "_rc=%ERRORLEVEL%"
del /Q "%_temp_cli%" "%_temp_version%" > nul 2>&1
if not "%_rc%"=="0" (
    echo [FAIL] compile failed / 編譯失敗
    pause
    exit /b 1
)

:: Retry with backoff: release\swift_tar.exe can be transiently locked (AV
:: real-time scan, a previous test run's process still releasing its handle)
:: causing a plain "move /Y" to fail with "Access is denied" -- silently,
:: since move's own exit code was never checked here before, leaving the OLD
:: exe in place while this script still printed [OK]. Same fix already used
:: by run_round.bat for lzfse.exe.
:: (Comments in this file stay English-only -- see the file header: non-ASCII
:: bytes on a comment line were found to corrupt cmd.exe's parsing here.)
powershell -NoProfile -Command "$src='%_build_exe%'; $dst='release\swift_tar.exe'; for ($i=1; $i -le 10; $i++) { try { if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }; Move-Item -LiteralPath $src -Destination $dst -Force; exit 0 } catch { Write-Output ('install retry '+$i+': '+$_.Exception.Message); Start-Sleep -Milliseconds 500 } }; exit 1"
if errorlevel 1 (
    echo [FAIL] could not install release\swift_tar.exe after retries / 重試多次後仍無法安裝 release\swift_tar.exe
    pause
    exit /b 1
)
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
