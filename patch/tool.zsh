#!/usr/bin/env zsh
# Select patch without taking Perl/BusyBox binaries or opaque Windows shims.
# 選擇 patch，避開 Perl／BusyBox 附帶版本與來源不明的 Windows shim。
swift_tar_patch_tool() {
  emulate -L zsh
  local candidate
  local -a candidates
  case $OSTYPE in
    msys*|mingw*|cygwin*)
      candidates=(/usr/bin/patch.exe /c/msys64/usr/bin/patch.exe
        "$HOME/scoop/apps/msys2/current/usr/bin/patch.exe"
        "${ProgramFiles:-C:/Program Files}/Git/usr/bin/patch.exe"
        "${(@f)$(whence -pa patch)}") ;;
    *) candidates=("${(@f)$(whence -pa patch)}") ;;
  esac
  for candidate in "${candidates[@]}"; do
    case ${candidate:l} in
      */perl/*|*/busybox/*|*/shims/*) continue ;;
    esac
    [[ -x $candidate && ! -d $candidate ]] || continue
    print -r -- "$candidate"
    return 0
  done
  print -ru2 -- 'No non-Perl patch found; install GNU patch (MSYS2 or Git for Windows on Windows). / 找不到非 Perl 的 patch；請安裝 GNU patch（Windows 可使用 MSYS2 或 Git for Windows）。'
  return 1
}
