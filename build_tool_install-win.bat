@echo off
setlocal

:: Bootstrap zsh before entering the full Windows toolchain installer. A clean
:: Git-for-Windows checkout has PowerShell but normally has no zsh, so the zsh
:: installer cannot install its own interpreter.
:: 在進入完整 Windows 工具鏈安裝器前先建立 zsh。乾淨的 Git for Windows 環境有
:: PowerShell，但通常沒有 zsh，因此 zsh 安裝器不能自行安裝自己的直譯器。
set "_zsh="
for /f "delims=" %%I in ('where zsh 2^>nul') do if not defined _zsh set "_zsh=%%I"
if defined _zsh goto run_installer

echo [INSTALL] Scoop and zsh bootstrap via PowerShell...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force; if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) { Invoke-RestMethod get.scoop.sh | Invoke-Expression }; if (-not (Get-Command zsh -ErrorAction SilentlyContinue)) { scoop install zsh }"
if errorlevel 1 exit /b 1

if defined SCOOP set "_zsh=%SCOOP%\shims\zsh.exe"
if not defined _zsh set "_zsh=%USERPROFILE%\scoop\shims\zsh.exe"
if not exist "%_zsh%" (
    echo [FAIL] zsh was installed but its shim was not found: %_zsh% >&2
    exit /b 1
)

:run_installer
"%_zsh%" "%~dp0build_tool_install-win.zsh"
exit /b %ERRORLEVEL%
