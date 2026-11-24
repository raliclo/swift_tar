#!/usr/bin/env zsh
# test_cmake_configure.zsh -- a CMake configure killed halfway must not poison the next build
# test_cmake_configure.zsh -- 中途被砍的 CMake 設定不得讓下一次建置沿用壞掉的目錄
#
#   zsh test/test_cmake_configure.zsh          run / 執行
#   zsh test/test_cmake_configure.zsh --help   print this synopsis and exit / 印出說明後結束
#
# Why: on Multissh-W11 a low-memory kill stopped a build while CMake was configuring libarchive,
# and the next build reused the half-written CMakeCache.txt and config.h and failed until the
# directory was deleted by hand (2026-11-20). cmake_configure.zsh marks a directory while it is
# being configured. Here a stand-in cmake writes a poisoned cache and is killed; the next run
# must start over. The build scripts are also checked to route every configure through it, so a
# configure added later cannot quietly skip the guard.
# 為什麼：Multissh-W11 上，一次記憶體不足的砍除在 CMake 設定 libarchive 時中斷了建置，下一次
# 建置沿用了寫一半的 CMakeCache.txt 與 config.h，直到手動刪掉目錄前都失敗（2026-11-20）。
# cmake_configure.zsh 在設定期間為目錄加上標記。這裡用一個替身 cmake 寫下壞掉的快取後被砍，
# 下一次執行必須重來。另外檢查各建置腳本的每一次設定都經過它，免得之後新增的設定悄悄繞過。

if [[ ${1:-} == --help || ${1:-} == -h ]]; then sed -n '2,18p' "${0:A}" | sed 's/^# \{0,1\}//'; exit 0; fi

ROOT="${0:A:h:h}"
pass=0 fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# A stand-in for cmake. MOCK_CMAKE=die writes a poisoned cache and kills itself, as an out-of-
# memory kill would; =fail writes one and exits 1; anything else writes a good one. Whatever the
# mode, finding a poisoned cache in -B is the reuse this guards against, and fails.
# cmake 的替身。MOCK_CMAKE=die 寫下壞掉的快取後砍掉自己，如同記憶體不足的砍除；=fail 寫下後以 1
# 結束；其他值寫下正常的。不論模式，在 -B 裡看到壞掉的快取就是這裡要防的沿用，以失敗結束。
mkdir -p "$TMP/bin"
cat > "$TMP/bin/cmake" <<'MOCK'
#!/bin/sh
dir=""
while [ $# -gt 0 ]; do
  case $1 in -B) dir=$2; shift ;; esac
  shift
done
[ -n "$dir" ] || { echo "mock cmake: no -B" >&2; exit 2; }
if [ -f "$dir/CMakeCache.txt" ] && grep -q POISON "$dir/CMakeCache.txt"; then
  echo "mock cmake: reused a half-written cache in $dir" >&2; exit 1
fi
mkdir -p "$dir"
case ${MOCK_CMAKE:-} in
  die)  echo POISON > "$dir/CMakeCache.txt"; kill -9 $$ ;;
  fail) echo POISON > "$dir/CMakeCache.txt"; exit 1 ;;
  *)    echo GOOD > "$dir/CMakeCache.txt" ;;
esac
MOCK
chmod +x "$TMP/bin/cmake"

# One configure, as a build script makes it: in its own zsh, sourcing the helper from the repo.
# 一次設定，如同建置腳本所做：在自己的 zsh 裡，從 repo 載入 helper。
configure() {   # mode dir -> status; output in $TMP/out
  ( cd "$TMP" && PATH="$TMP/bin:$PATH" MOCK_CMAKE=$1 \
      zsh -f -c '. "$1/cmake_configure.zsh" && cmake_configure "$2" -S src' _ "$ROOT" "$2" ) > "$TMP/out" 2>&1
}

if [[ ! -f $ROOT/cmake_configure.zsh ]]; then
  bad "cmake_configure.zsh exists"
else
  # Killed halfway, then run again. / 中途被砍，再跑一次。
  rc=0; configure die build/a || rc=$?
  (( rc != 0 )) && ok "a killed configure fails" || bad "a killed configure fails (rc $rc)"
  [[ -e $TMP/build/a/.swift_tar-configuring ]] && ok "a killed configure leaves its marker" \
    || bad "a killed configure leaves its marker"
  rc=0; configure ok build/a || rc=$?
  [[ $rc == 0 && $(<"$TMP/build/a/CMakeCache.txt") == GOOD ]] \
    && ok "the next configure starts over instead of reusing the half-written cache" \
    || bad "the next configure starts over instead of reusing the half-written cache (rc $rc; $(tr '\n' '|' < "$TMP/out"))"
  grep -q 'did not finish' "$TMP/out" && ok "and it says why it removed the directory" \
    || bad "and it says why it removed the directory ($(tr '\n' '|' < "$TMP/out"))"
  [[ ! -e $TMP/build/a/.swift_tar-configuring ]] && ok "a configure that succeeds removes its marker" \
    || bad "a configure that succeeds removes its marker"

  # A configure that fails on its own is redone from empty too. / 自行失敗的設定也從空目錄重來。
  rc=0; configure fail build/b || rc=$?
  (( rc == 1 )) && ok "a failed configure passes cmake's status on" || bad "a failed configure passes cmake's status on (rc $rc)"
  rc=0; configure ok build/b || rc=$?
  [[ $rc == 0 && $(<"$TMP/build/b/CMakeCache.txt") == GOOD ]] && ok "after a failed configure the next one starts over" \
    || bad "after a failed configure the next one starts over (rc $rc; $(tr '\n' '|' < "$TMP/out"))"

  # A directory without the marker -- one from a finished configure, or from before the guard --
  # is reused, not removed: an incremental build stays incremental.
  # 沒有標記的目錄——來自完成的設定，或來自加上防護之前——被沿用而非移除：增量建置維持增量。
  mkdir -p "$TMP/build/c"; echo GOOD > "$TMP/build/c/CMakeCache.txt"; echo kept > "$TMP/build/c/object.o"
  rc=0; configure ok build/c || rc=$?
  [[ $rc == 0 && -f $TMP/build/c/object.o ]] && ok "a directory without the marker is reused, not removed" \
    || bad "a directory without the marker is reused, not removed (rc $rc)"
fi

# Every configure in the build scripts goes through cmake_configure. build_zlib-win.zsh is left out
# on purpose: it removes its build directory before every configure.
# 建置腳本裡的每一次設定都經過 cmake_configure。build_zlib-win.zsh 刻意不列：它每次設定前都先刪掉
# 建置目錄。
for s in build_libarchive.zsh build_libarchive-win.zsh build_codecs.zsh build_zstd-win.zsh \
         compile_tar-linux.zsh compile_tar-musl.zsh; do
  raw=$(grep -nE '^[[:space:]]*([A-Za-z_]+=[^[:space:]]+[[:space:]]+)*cmake[[:space:]]+-S' "$ROOT/$s")
  [[ -z $raw ]] && ok "$s: no configure bypasses cmake_configure" \
    || bad "$s: no configure bypasses cmake_configure (${raw//$'\n'/ | })"
  grep -qE '^[[:space:]]*\. \./cmake_configure\.zsh' "$ROOT/$s" && ok "$s: loads cmake_configure.zsh" \
    || bad "$s: loads cmake_configure.zsh"
done

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" = 0 ]
