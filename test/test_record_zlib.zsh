#!/usr/bin/env zsh
# test_record_zlib.zsh -- the macOS build records the system zlib's version, or the OS build.
# test_record_zlib.zsh -- macOS 建置會記下系統 zlib 的版本，讀不到時改記 OS build。
#
#   ./test/test_record_zlib.zsh          # run / 執行
#   ./test/test_record_zlib.zsh --help   # this synopsis / 本說明
#
# Runs record_linked and record_zlib from compile_tar.zsh against a fake otool. Case 1 is the
# normal otool line; cases 2 and 3 have no numeric current version, and must fall back to
# macos-<productVersion>-<buildVersion> from sw_vers rather than record a broken value.
# 以假的 otool 執行 compile_tar.zsh 的 record_linked 與 record_zlib。第 1 項是正常的 otool
# 輸出；第 2、3 項沒有數字形式的 current version，必須改用 sw_vers 的
# macos-<productVersion>-<buildVersion>，而不是記下一個壞掉的值。
set -u

script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  for l in "${(@f)$(<"$script_path")}"; do
    [[ $l == '#!'* ]] && continue
    [[ $l == '#'* ]] || break
    l=${l#\#}; printf '%s\n' "${l# }"
  done
  exit 0
fi
ROOT="${script_path:h:h}"

if [[ $(uname) != Darwin ]]; then
  print "SKIP: macOS only / 僅限 macOS"
  exit 0
fi

T=$(mktemp -d -t test_record_zlib)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
fns=$(sed -n '/^record_linked() {/,/^}/p;/^record_zlib() {/,/^}/p' "$ROOT/compile_tar.zsh")
[[ $fns == *'record_zlib() {'* ]] || { print "FAIL: record_zlib not found in compile_tar.zsh / 找不到 record_zlib"; exit 1; }

os_id="macos-$(sw_vers -productVersion)-$(sw_vers -buildVersion)"
pass=0 fail=0
check() {   # name  otool-output  expected-version / 名稱 假 otool 輸出 預期版本
  print -r -- "#!/bin/zsh
print -r -- ${(q)2}" > "$T/bin/otool"
  chmod +x "$T/bin/otool"
  local got
  got=$(PATH="$T/bin:$PATH" zsh -c "$fns
record_zlib")
  local want="zlib_dylib_version=$3
zlib_path=/usr/lib/libz.1.dylib
zlib_linkage=dynamic"
  if [[ $got == $want ]]; then
    print "PASS: $1"; (( pass++ ))
  else
    print "FAIL: $1"; print -r -- "  got / 實得:"; print -r -- "$got"; (( fail++ ))
  fi
}

nl=$'\n'
check "otool current version / otool 有 current version" \
  "release/swift_tar:${nl}	/usr/lib/libz.1.dylib (compatibility version 1.0.0, current version 1.2.12)" 1.2.12
check "no current version -> OS build / 沒有 current version 改用 OS build" \
  "release/swift_tar:${nl}	/usr/lib/libz.1.dylib (compatibility version 1.0.0)" "$os_id"
check "no libz line -> OS build / 沒有 libz 這一行改用 OS build" \
  "release/swift_tar:" "$os_id"

print "passed=$pass failed=$fail"
(( fail == 0 ))
