# linux_sos.zsh -- sourced by release.zsh: which Swift runtime .so files a glibc binary loads
# linux_sos.zsh —— 由 release.zsh source：glibc 執行檔實際會載入哪些 Swift runtime .so
#
# The linux-<arch>-glibc archive carries the Swift runtime in lib/ (user's decision,
# 2026-11-04), as the Windows archive carries its DLLs. Kept apart from release.zsh, like
# win_dlls.zsh, so test/test_release.zsh can run it anywhere with a stand-in readelf.
# linux-<arch>-glibc 封存把 Swift runtime 帶在 lib/ 裡（使用者 2026-11-04 決定），如同 Windows 封存
# 帶著它的 DLL。與 win_dlls.zsh 一樣和 release.zsh 分開，讓 test/test_release.zsh 能在任何地方以替身
# readelf 執行。

# swift_tar_linux_sos <readelf> <elf> <runtime dir>
#   Follow the DT_NEEDED entries of <elf>, then those of every library reached, and print the
#   path of each one found in <runtime dir>, one per line. Names not found there (libc.so.6,
#   libm, libstdc++, libbz2) belong to the system and are skipped. A readelf that fails is an
#   error, not "no NEEDED", for the reason win_dlls.zsh gives (2026-10-31 review S3).
#   順著 <elf> 的 DT_NEEDED，再順著每個找到的函式庫的 DT_NEEDED，把在 <runtime dir> 裡找到的每一個
#   逐行印出路徑。在那裡找不到的名稱（libc.so.6、libm、libstdc++、libbz2）屬於系統，略過。readelf
#   失敗是錯誤，不是「沒有 NEEDED」，理由與 win_dlls.zsh 相同（2026-10-31 審查 S3）。
swift_tar_linux_sos() {
  emulate -L zsh
  setopt no_unset
  local readelf=$1 start=$2 rt=$3 elf so dump line f
  local -A shipped=()
  local -a queue=("$start")
  while (( $#queue )); do
    elf=${queue[1]}
    shift queue
    if ! dump=$("$readelf" -dW "$elf"); then
      print -ru2 -- "swift_tar_linux_sos: $readelf -dW $elf failed / 執行失敗"
      return 1
    fi
    for line in "${(@f)dump}"; do
      [[ $line == *'(NEEDED)'*'['*']'* ]] || continue
      so=${${line#*\[}%%\]*}
      f=$rt/$so
      [[ -f $f && -z ${shipped[$so]-} ]] || continue
      shipped[$so]=$f
      queue+=("$f")
    done
  done
  (( ${#shipped} )) && print -rl -- "${(@v)shipped}"
  return 0
}

# swift_tar_linux_runtime <version file> -- print the Swift runtime directory the build recorded
#   (swift_runtime_dir=, written by compile_tar-linux.zsh). Returns 1 when there is no record and
#   2 when the recorded directory no longer holds libswiftCore.so. Never guessed, for the reason
#   swift_tar_win_runtime gives: a guess ships a runtime the binary was not built against.
# swift_tar_linux_runtime <version 檔> —— 印出建置記下的 Swift runtime 目錄（swift_runtime_dir=，由
#   compile_tar-linux.zsh 寫入）。沒有紀錄回傳 1，紀錄的目錄已沒有 libswiftCore.so 回傳 2。絕不猜測，
#   理由與 swift_tar_win_runtime 相同：猜出來的會是執行檔不是以之建置的 runtime。
swift_tar_linux_runtime() {
  emulate -L zsh
  local line rt=""
  for line in "${(@f)$(<$1)}"; do
    [[ $line == swift_runtime_dir=* ]] && rt=${line#swift_runtime_dir=}
  done
  [[ -n $rt ]] || return 1
  [[ -f $rt/libswiftCore.so ]] || return 2
  print -r -- "$rt"
}
