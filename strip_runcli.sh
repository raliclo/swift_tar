#!/usr/bin/env zsh
# =====================================================================
# strip_runcli.sh -- copy a Swift CLI source with its top-level runCLI() removed.
# strip_runcli.sh -- 複製 Swift CLI 原始碼，並移除其頂層的 runCLI()。
#
# lzfse-cli.swift is a standalone program: its last line calls runCLI() at file
# scope. Swift allows top-level statements only in main.swift, so including the
# file in a multi-file build fails unless that one line is dropped.
# lzfse-cli.swift 是獨立程式：其最後一行在檔案作用域呼叫 runCLI()。Swift 僅允許
# main.swift 有頂層敘述，故若不移除該行，將此檔納入多檔編譯就會失敗。
#
# compile_tar.sh and compile_tar-linux.sh do this inline with the same grep.
# compile_tar-win.bat cannot: quoting a redirect through cmd.exe into zsh is
# fragile -- the tested inline form died with "The filename, directory name, or
# volume label syntax is incorrect" before zsh ever ran. A script file takes the
# paths as plain arguments and sidesteps the quoting entirely.
# compile_tar.sh 與 compile_tar-linux.sh 以相同的 grep 內聯處理。
# compile_tar-win.bat 無法比照：把重導向的引號經 cmd.exe 傳進 zsh 十分脆弱——實測
# 的內聯寫法在 zsh 尚未執行前就以「The filename, directory name, or volume label
# syntax is incorrect」失敗。改用腳本檔，路徑以一般參數傳入，可完全避開引號問題。
#
# This replaces a PowerShell one-liner (Get-Content | Where-Object | Set-Content).
# The user-level scripting policy reserves PowerShell for UAC elevation shims,
# and this is plain text filtering. It also drops the UTF-8 BOM that
# `Set-Content -Encoding UTF8` prepends under Windows PowerShell 5.1.
# 本檔取代原本的 PowerShell 單行指令。使用者層級的腳本政策僅保留 PowerShell 作為
# UAC 提權 shim，而這裡只是純文字過濾。同時也去掉了 Windows PowerShell 5.1 的
# `Set-Content -Encoding UTF8` 會加上的 UTF-8 BOM。
#
# Usage / 用法:
#   zsh ./strip_runcli.sh <source.swift> <dest.swift>
# =====================================================================
set -euo pipefail

src="${1:?Usage: strip_runcli.sh <source.swift> <dest.swift>}"
dest="${2:?Usage: strip_runcli.sh <source.swift> <dest.swift>}"

[[ -f "$src" ]] || { print -u2 -- "[strip_runcli] source not found / 找不到來源: $src"; exit 1 }

# Fail if the marker is absent rather than emitting an unchanged copy. Without
# this the build proceeds and swiftc reports "expressions are not allowed at the
# top level" against a temp file, which names neither this step nor the rename
# upstream that caused it.
# 找不到標記時直接失敗，而非輸出一份未經修改的副本。否則建置會繼續，由 swiftc 對著
# 一個暫存檔報「expressions are not allowed at the top level」——該訊息既不指向本
# 步驟，也不指向上游那次造成問題的改名。
grep -q '^runCLI()$' "$src" || {
    print -u2 -- "[strip_runcli] no top-level runCLI() in $src / 其中沒有頂層 runCLI()"
    exit 1
}

grep -v '^runCLI()$' "$src" > "$dest"
