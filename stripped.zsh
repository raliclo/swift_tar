# stripped.zsh -- sourced by release.zsh and publish.zsh: is a binary stripped?
# stripped.zsh —— 由 release.zsh 與 publish.zsh source：執行檔是否已 strip？
#
# One check for the three formats a release ships (Mach-O, static ELF, PE), so the node that
# packs an archive and the Mac that publishes it cannot disagree about what "stripped" means.
# 一份檢查涵蓋發布的三種格式（Mach-O、靜態 ELF、PE），讓打包的節點與發布的 Mac 對「已 strip」的
# 定義不會不一致。

# swift_tar_nm: the nm to use, llvm-nm first. macOS's /usr/bin/nm is LLVM's and reads all three
# formats; GNU nm reads ELF and PE and fails on Mach-O, which the caller then refuses.
# swift_tar_nm：要用的 nm，llvm-nm 優先。macOS 的 /usr/bin/nm 就是 LLVM 的，三種格式都讀得懂；GNU nm
# 讀得懂 ELF 與 PE，遇到 Mach-O 則失敗，呼叫端會因此拒絕。
swift_tar_nm() {
  local t
  for t in llvm-nm nm; do
    command -v $t >/dev/null 2>&1 && { print -r -- $t; return 0; }
  done
  return 1
}

# swift_tar_unstripped <nm> <file>
#   0: stripped. 1: symbols are left, the first few printed. 2: nm could not read the file.
#   A stripped Mach-O executable keeps exactly one defined symbol, __mh_execute_header, which
#   dyld needs; a stripped ELF or PE has none, and nm says "no symbols" for it.
#   0：已 strip。1：仍有符號，印出前幾個。2：nm 讀不了這個檔案。
#   已 strip 的 Mach-O 執行檔恰好保留一個已定義符號 __mh_execute_header，dyld 需要它；已 strip 的
#   ELF 或 PE 一個都沒有，nm 對它說「no symbols」。
swift_tar_unstripped() {
  emulate -L zsh
  local out
  out=$("$1" -a --defined-only "$2" 2>&1) || { print -r -- "$out"; return 2 }
  local -a syms=(${(f)out})
  syms=(${syms:#*: no symbols})
  syms=(${syms:#* __mh_execute_header})
  (( ${#syms} == 0 )) && return 0
  print -rl -- "${(@)syms[1,5]}"
  return 1
}
