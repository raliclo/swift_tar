@echo off
:: Shim only. All build logic is in compile_tar-win.zsh -- edit that, not this.
:: This file exists so the build can still be started by double-clicking it in
:: Explorer, or from a cmd prompt. `zsh ./build.zsh` calls the zsh script direct.
::
:: Keep this file ASCII-only and one command long. cmd.exe mis-parses an LF-only
:: batch file that contains non-ASCII bytes, executing fragments of comment text
:: as commands; staying ASCII is what lets this file use LF like the rest of the
:: repository. Bilingual text belongs in the zsh script, which has no such limit.
zsh ./compile_tar-win.zsh %*
