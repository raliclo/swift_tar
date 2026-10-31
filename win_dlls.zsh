# win_dlls.zsh -- sourced by release.zsh: which runtime DLLs a Windows binary actually loads
# win_dlls.zsh —— 由 release.zsh source：Windows 執行檔實際會載入哪些 runtime DLL
#
# Kept apart from release.zsh so test/test_release.zsh can run it on macOS with a stand-in
# objdump; the Windows branch of release.zsh itself only runs on Windows.
# 與 release.zsh 分開，讓 test/test_release.zsh 能在 macOS 上以替身 objdump 執行；release.zsh 的
# Windows 分支本身只在 Windows 上跑。

# swift_tar_win_dlls <objdump> <pe> <runtime bin dir>
#   Follow the PE imports from <pe>, then those of every DLL reached, and print the on-disk path of
#   each one found in <runtime bin dir>, one per line. Names are matched without regard to case,
#   since import tables say MSVCP140.dll where the directory holds msvcp140.dll, and the path
#   printed is the directory's own spelling. Imports not found there (KERNEL32, the UCRT
#   api-ms-* sets) belong to the system and are skipped.
#   順著 <pe> 的 PE import，再順著每個找到的 DLL 的 import，把在 <runtime bin dir> 裡找到的每一個以
#   磁碟上的路徑逐行印出。名稱比對不分大小寫——import 表寫 MSVCP140.dll，目錄裡是 msvcp140.dll——
#   印出的是目錄裡原本的拼法。在那裡找不到的 import（KERNEL32、UCRT 的 api-ms-*）屬於系統，略過。
swift_tar_win_dlls() {
  emulate -L zsh
  setopt extended_glob no_unset
  local objdump=$1 start=$2 rt=$3 f pe dll key dump
  local -A on_disk=() shipped=()
  for f in "$rt"/(#i)*.dll(N.); do on_disk[${f:t:l}]=$f; done
  local -a queue=("$start")
  while (( $#queue )); do
    pe=${queue[1]}
    shift queue
    # objdump's own failure is an error, not "no imports": inside the pipeline it read as an
    # empty list, so the release shipped without the DLLs it needed (2026-10-31 review S3).
    # objdump 本身失敗是錯誤，不是「沒有 import」：放在管線裡時它被讀成空清單，於是發行版少了
    # 需要的 DLL（2026-10-31 審查 S3）。
    if ! dump=$("$objdump" -p "$pe"); then
      print -ru2 -- "swift_tar_win_dlls: $objdump -p $pe failed / 執行失敗"
      return 1
    fi
    for dll in ${(f)"$(print -r -- "$dump" | sed -n 's/^[[:space:]]*DLL Name:[[:space:]]*//p' | tr -d '\r')"}; do
      key=${dll:l}
      f=${on_disk[$key]-}
      [[ -n $f && -z ${shipped[$key]-} ]] || continue
      shipped[$key]=$f
      queue+=("$f")
    done
  done
  (( ${#shipped} )) && print -rl -- "${(@v)shipped}"
  return 0
}

# swift_tar_win_runtime <pe> -- print the Swift runtime bin directory <pe> was built against, read
#   from <pe>.runtime, which compile_tar-win.zsh writes beside the exe. Returns 1 when there is no
#   record and 2 when the recorded directory no longer holds swiftCore.dll. Never falls back to the
#   newest installed runtime: that fallback is what shipped another runtime's DLLs whenever Swift
#   was upgraded between build and release (2026-10-30 review, item 5).
# swift_tar_win_runtime <pe> —— 印出 <pe> 建置時所用的 Swift runtime bin 目錄，讀自 compile_tar-win.zsh
#   寫在 exe 旁的 <pe>.runtime。沒有紀錄回傳 1，紀錄的目錄已沒有 swiftCore.dll 回傳 2。絕不退回
#   「已安裝的最新版」：建置與發布之間升級 Swift 時，正是這個退路帶上了另一份 runtime 的 DLL
#   （2026-10-30 審查第 5 項）。
swift_tar_win_runtime() {
  emulate -L zsh
  local record=$1.runtime rt
  [[ -r $record ]] || return 1
  rt=$(<$record)
  [[ -n $rt && -f $rt/swiftCore.dll ]] || return 2
  printf '%s\n' "$rt"
}

# swift_tar_ships_msvc_runtime <path>... -- true if any of them is a Microsoft Visual C++ runtime
# DLL. Each path is tested on its own: the first version tested a hash's keys inside (( )), where
# they were joined into one string, so the answer depended on which key came first.
# swift_tar_ships_msvc_runtime <路徑>... —— 其中任何一個是 Microsoft Visual C++ runtime DLL 時為真。
# 逐一判斷：第一版在 (( )) 裡測 hash 的鍵，鍵在那裡被接成一個字串，答案取決於哪個鍵排第一。
swift_tar_ships_msvc_runtime() {
  emulate -L zsh
  setopt extended_glob
  local p
  for p in "$@"; do
    [[ ${p:t:l} == (vcruntime|msvcp|concrt|vccorlib)*.dll ]] && return 0
  done
  return 1
}
