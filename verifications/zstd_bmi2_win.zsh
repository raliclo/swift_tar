#!/usr/bin/env zsh
# zstd_bmi2_win.zsh -- does building swift_tar's zstd with clang instead of MSVC turn on BMI2, and is it faster?
# zstd_bmi2_win.zsh -- 把 swift_tar 的 zstd 從 MSVC 改用 clang 建置，會不會開啟 BMI2？會不會更快？
#
#   zsh verifications/zstd_bmi2_win.zsh [CORPUS_DIR=../claw-code]
#   ROUNDS=5 BUILD=C:/Users/$USER/tmp/zbmi2 zsh verifications/zstd_bmi2_win.zsh ../claw-code
#   zsh verifications/zstd_bmi2_win.zsh --help
#
# Builds zstd.exe from the zstd submodule (v1.5.7) six ways, out of tree under BUILD, then runs
# zstd -b over a tar of CORPUS_DIR, interleaved, best of ROUNDS, at levels 9 (swift_tar's default)
# and 3, with -B4M (TAR_CHUNK_SIZE = 1<<22, one frame per chunk), single-threaded.
# 從 zstd 子模組（v1.5.7）以六種方式在 BUILD 底下樹外建出 zstd.exe，再對 CORPUS_DIR 打成的 tar 交錯執行
# zstd -b，取 ROUNDS 輪中最好的一次；等級 9（swift_tar 預設）與 3，-B4M（每 4 MiB chunk 一個 frame），單執行緒。
#   a  MSVC cl.exe, newest VS generator (VS 17 2022 on 2026-10-30) -- build_zstd-win.zsh before 2026-10-30 / 2026-10-30 前的 build_zstd-win.zsh
#   b  clang-cl, -DDYNAMIC_BMI2=0             c  clang-cl, default
#   d  clang (GNU driver), -DDYNAMIC_BMI2=0   e  clang (GNU driver), default
#   f  clang -mbmi2 (STATIC_BMI2) -- a ceiling only: the binary needs a BMI2 CPU, not a candidate
#      clang -mbmi2（STATIC_BMI2）——只當上限參考：執行檔需要支援 BMI2 的 CPU，不是候選方案
# clang/clang-cl/lld-link are the newest installed Swift toolchain's (6.4.1 for the 2026-10-30 run;
# the [Info] clang line records which). All use CMake's Release flags. b-f build
# through ../win_clang_cmake.zsh (NMake from the VS build tools, as the real builders do); the run
# recorded on 2026-10-30 used Ninja, which passes the same compile flags.
# clang/clang-cl/lld-link 皆為最新安裝的 Swift 工具鏈所附（2026-10-30 那次是 6.4.1；[Info] clang 那行記錄實際版本），
# 全部使用 CMake 的 Release 旗標。b-f 經由
# ../win_clang_cmake.zsh 建置（與正式建置腳本相同，用 VS 建置工具的 NMake）；2026-10-30 記錄的那次執行
# 用的是 Ninja，傳入的編譯旗標相同。
#
# Why c and e cannot deliver BMI2 (found 2026-10-30): portability_macros.h sets DYNAMIC_BMI2=1 for any
# clang, but compiler.h defines TARGET_ATTRIBUTE only under __GNUC__, which clang does not define when
# targeting MSVC -- neither clang-cl nor the GNU driver. So the _bmi2 copies are compiled as plain
# x86-64: more code, a cpuid branch, and no BMI2 instruction. The script counts shlx/shrx/bzhi with
# llvm-objdump to show it rather than assume it. zstd's CMake also adds -DZSTD_DISABLE_ASM on Windows,
# so the BMI2 assembly Huffman decoder is off for every variant here.
# 為何 c 與 e 拿不到 BMI2（2026-10-30 發現）：portability_macros.h 對所有 clang 設 DYNAMIC_BMI2=1，但
# compiler.h 只在 __GNUC__ 下定義 TARGET_ATTRIBUTE，而 clang 以 MSVC 為目標時不定義它——clang-cl 與 GNU
# 驅動皆然。於是 _bmi2 副本照一般 x86-64 編譯：程式更大、多一個 cpuid 分支、沒有任何 BMI2 指令。腳本以
# llvm-objdump 數 shlx/shrx/bzhi 來呈現，而非假設。zstd 的 CMake 在 Windows 也會加 -DZSTD_DISABLE_ASM，
# 因此組語版 BMI2 Huffman 解碼器在此所有版本都是關的。
#
# BUILD must be a short path: under the scratchpad, MSBuild's .tlog path passed 260 characters and
# variant a failed in CMake's compiler check (MSB6003 DirectoryNotFoundException).
# BUILD 必須是短路徑：放在 scratchpad 底下時 MSBuild 的 .tlog 路徑超過 260 字元，a 在 CMake 的編譯器檢查失敗。
# Output: zstd_bmi2_win_output.txt (console) and zstd_bmi2_win.csv2 (best-of table), next to this script.
# 輸出：本腳本旁的 zstd_bmi2_win_output.txt（主控台）與 zstd_bmi2_win.csv2（最佳值表）。
set -uo pipefail
script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then sed -n '2,44p' "$script_path" | sed 's/^# \{0,1\}//'; exit 0; fi
(( $# <= 1 )) || { printf 'usage: %s [CORPUS_DIR]  (--help)\n' "${script_path:t}" >&2; exit 2 }

SCRIPT_DIR=${script_path:h}
REPO=${SCRIPT_DIR:h}
# CORRECTED 2026-10-31: the synopsis said ../../claw-code, one level too high; from the swift_tar
# root this default is ../claw-code, and the old spelling stopped with "corpus not found".
# test/test_doc_consistency.zsh keeps the synopsis and this line agreeing.
# 更正 2026-10-31：用法原本寫 ../../claw-code，多了一層；從 swift_tar 根目錄看，此預設是 ../claw-code，舊寫法
# 會以「corpus not found」中止。test/test_doc_consistency.zsh 讓用法與這一行保持一致。
CORPUS=${1:-${REPO:h}/claw-code}
ROUNDS=${ROUNDS:-5}
BUILD=${BUILD:-C:/Users/${USER:-$USERNAME}/tmp/zbmi2}
OUTPUT_TXT=$SCRIPT_DIR/zstd_bmi2_win_output.txt
OUTPUT_CSV2=$SCRIPT_DIR/zstd_bmi2_win.csv2
[[ -d $CORPUS ]] || { printf '[Error] corpus not found: %s\n' "$CORPUS" >&2; exit 1 }
# CORRECTED 2026-11-07: TC named Toolchains/6.4.1+Asserts, which the 6.4.2 installer deleted, so the script
# stopped here. It is now the newest installed toolchain by numeric sort (n), as compile_tar-win.zsh picks it.
# 更正 2026-11-07：TC 原本寫死 Toolchains/6.4.1+Asserts，6.4.2 安裝程式已將其刪除，腳本在此中止。
# 現改為以數值排序（n）挑出的最新安裝工具鏈，與 compile_tar-win.zsh 的選法相同。
tcs=("$(cygpath -u "$LOCALAPPDATA")"/Programs/Swift/Toolchains/*/usr/bin(/Nn))
(( ${#tcs} )) || { printf '[Error] no Swift toolchain under %s/Programs/Swift/Toolchains\n' "$LOCALAPPDATA" >&2; exit 1 }
TC=$(cygpath -m "${tcs[-1]}")
# win_clang_cmake (b-f) takes its driver from the swiftc on PATH, so put the same toolchain first: otherwise
# a shell still naming a deleted version stops at "swiftc not on PATH" (measured 2026-11-07).
# win_clang_cmake（b-f）以 PATH 上的 swiftc 決定驅動程式，故把同一個工具鏈放在最前面：否則仍指向已刪除
# 版本的 shell 會停在「swiftc not on PATH」（2026-11-07 實測）。
export PATH="${tcs[-1]}:$PATH"
[[ -x $TC/clang-cl.exe && -x $TC/llvm-objdump.exe ]] || { printf '[Error] clang-cl.exe or llvm-objdump.exe missing in %s\n' "$TC" >&2; exit 1 }
exec > >(tee "$OUTPUT_TXT") 2>&1

variants=(a b c d e f)
levels=(9 3)
# wmic is gone on this Windows build; the registry holds the same name. / 此版 Windows 已無 wmic，改讀登錄檔。
cpu=$(MSYS2_ARG_CONV_EXCL='*' reg query 'HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0' /v ProcessorNameString \
      | tr -d '\r' | awk '/ProcessorNameString/ { sub(/.*REG_SZ +/, ""); sub(/ +$/, ""); print }')
printf '[Info] date: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf '[Info] os: %s   cpu: %s\n' "$(uname -sr)" "$cpu"
printf '[Info] zstd: %s   swift_tar: %s\n' "$(git -C "$REPO/zstd" describe --tags)" "$(git -C "$REPO" describe --tags --always --dirty)"
printf '[Info] clang: %s\n' "$("$TC/clang.exe" --version | head -1)"
printf '[Info] corpus: %s (%s MB, %s files)   rounds: %s\n' "$CORPUS" "$(du -sm "$CORPUS" | cut -f1)" "$(find "$CORPUS" -type f | wc -l)" "$ROUNDS"

# ---- build / 建置 ----
rm -rf -- "$BUILD"; mkdir -p "$BUILD"
common=(-DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_PROGRAMS=ON
        -DZSTD_BUILD_TESTS=OFF -DZSTD_LEGACY_SUPPORT=OFF -DZSTD_MULTITHREAD_SUPPORT=OFF)
src=$REPO/zstd/build/cmake
. "$REPO/win_clang_cmake.zsh"
typeset -A exe
# Variant a's Visual Studio generator follows the newest installed VS, as the Swift toolchain above does.
# CORRECTED 2026-11-07: it named "Visual Studio 17 2022"; this machine now has only VS 18 (2026), and
# CMake stopped with "could not find any instance of Visual Studio" before a was built.
# a 的 Visual Studio 產生器跟著最新安裝的 VS 走，與上面的 Swift 工具鏈相同。
# 更正 2026-11-07：原本寫死 "Visual Studio 17 2022"；本機如今只有 VS 18（2026），CMake 在建出 a 之前
# 就以「could not find any instance of Visual Studio」中止。
vswhere='/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe'
[[ -x $vswhere ]] || { printf '[Error] vswhere.exe not found; run: zsh ./build_tool_install-win.zsh\n' >&2; exit 1 }
vs_major=$(MSYS2_ARG_CONV_EXCL='*' "$vswhere" -latest -products '*' -property catalog_productLineVersion | tr -d '\r')
vs_gen=$(cmake --help | tr -d '\r' | grep -o "Visual Studio $vs_major [0-9][0-9][0-9][0-9]" | head -1)
[[ -n $vs_gen ]] || { printf '[Error] cmake has no generator for Visual Studio %s\n' "${vs_major:-?}" >&2; exit 1 }
printf '[Info] variant a generator: %s\n' "$vs_gen"
printf '\n=== build / 建置 ===\n'
for v in $variants; do
  case $v in
    a) gen=(-G "$vs_gen" -A x64) ;;
    *) cc=clang; [[ $v == [bc] ]] && cc=clang-cl
       flags=''; [[ $v == [bd] ]] && flags=-DDYNAMIC_BMI2=0; [[ $v == f ]] && flags=-mbmi2
       win_clang_cmake $cc "$BUILD/$v/lib" || exit 1
       gen=("${win_cmake_args[@]}" -DCMAKE_CXX_COMPILER="$win_cc" -DCMAKE_ASM_COMPILER="$win_cc"
            -DCMAKE_LINKER="$TC/lld-link.exe" -DCMAKE_C_FLAGS="$flags") ;;
  esac
  cmake -S "$src" -B "$BUILD/$v" "${gen[@]}" "${common[@]}" > "$BUILD/$v.cfg.log" 2>&1 \
    && cmake --build "$BUILD/$v" --config Release --target zstd > "$BUILD/$v.build.log" 2>&1
  rc=$?
  exe[$v]=$(find "$BUILD/$v/programs" -name zstd.exe | head -1)
  (( rc == 0 )) && [[ -x ${exe[$v]} ]] || { printf '[Error] build %s rc=%s, see %s\n' $v $rc "$BUILD/$v.*.log"; exit 1 }
done

# ---- size and BMI2 instruction count / 大小與 BMI2 指令數 ----
printf '\n=== size and BMI2 instructions (llvm-objdump) / 大小與 BMI2 指令數 ===\n'
printf '  %-2s %10s %10s %6s %6s %6s %8s\n' var bytes .text shlx shrx bzhi warnings
typeset -A bytes
for v in $variants; do
  "$TC/llvm-objdump.exe" -d --no-show-raw-insn "${exe[$v]}" > "$BUILD/$v.dis"
  bytes[$v]=$(wc -c < "${exe[$v]}")
  text=$(( 16#$("$TC/llvm-objdump.exe" -h "${exe[$v]}" | awk '$2 == ".text" { print $3 }') ))
  printf '  %-2s %10s %10s %6s %6s %6s %8s\n' $v ${bytes[$v]} $text \
    "$(grep -c $'\tshlx' "$BUILD/$v.dis")" "$(grep -c $'\tshrx' "$BUILD/$v.dis")" "$(grep -c $'\tbzhi' "$BUILD/$v.dis")" \
    "$(grep -cE 'warning: |warning C[0-9]+:' "$BUILD/$v.build.log")"
done

# ---- benchmark / 量測 ----
corpus_tar=$BUILD/corpus.tar
# --force-local: GNU tar otherwise reads "C:/..." as host "C" ("Cannot connect to C: resolve failed").
# --force-local：否則 GNU tar 把 "C:/..." 當成遠端主機 "C"。
tar --force-local -cf "$corpus_tar" -C "${CORPUS:h}" "${CORPUS:t}" || exit 1
printf '\n=== zstd -b -B4M --single-thread, interleaved / 交錯執行 (corpus tar %s bytes) ===\n' "$(wc -c < "$corpus_tar")"
typeset -A best_c best_d ratio
integer retries=0
for (( r = 1; r <= ROUNDS; r++ )); do
  for l in $levels; do
    for v in $variants; do
      # --single-thread: the build has ZSTD_MULTITHREAD_SUPPORT=OFF ("ZSTD_c_nbWorkers ... Unsupported
      # parameter" otherwise). No -q: it drops the result line. The last line carrying both speeds is it,
      # except that a decode-phase progress line can read "(x0.000), 0.00 MB/s, N MB/s" -- seen once in
      # the first claw-code run (r5 L9 f), which put ratio 0.000 in the table -- so those are skipped.
      # --single-thread：建置關閉多執行緒。不用 -q：它連結果行也省略。最後一行同時有兩個速度者即結果；
      # 但解壓階段的進度行可能是「(x0.000), 0.00 MB/s, N MB/s」（第一次 claw-code 執行的 r5 L9 f 出現過，
      # 使表中壓縮比成為 0.000），故略過。
      # About one run in 60 zstd -b loses its compression result: it prints
      # "1409474560 ->4294967295 (x0.000), 0.00 MB/s, 609.8 MB/s" and exits 0. Seen on a, e and f
      # (MSVC and clang alike), so it is the bench on Windows, not the compiler. Such a run is retried
      # (at most 3 attempts) and every retry is printed, so the count is in the output, not hidden.
      # 約每 60 次會有一次 zstd -b 遺失壓縮結果：印出「->4294967295 (x0.000), 0.00 MB/s, …」且以 0
      # 結束。a、e、f 都出現過（MSVC 與 clang 皆然），因此是 Windows 上 bench 的問題，與編譯器無關。
      # 這種情況重試（最多 3 次），每次重試都印出，次數留在輸出裡，不藏起來。
      line=''
      for (( try = 1; try <= 3; try++ )); do
        raw=$("${exe[$v]}" --single-thread -b$l -B4M -i3 "$corpus_tar" 2>&1 | tr '\r' '\n'); zrc=$?
        line=$(printf '%s\n' "$raw" | grep -E 'MB/s,.*MB/s' | grep -vF '(x0.000)' | tail -1)
        [[ -n $line ]] && break
        printf '  [Warn] r%s L%s %s attempt %s: zstd rc=%s, no compression result: %s\n' $r $l $v $try $zrc \
          "$(printf '%s\n' "$raw" | grep 'MB/s' | tail -1)"
        (( retries++ ))
      done
      [[ $line =~ '\(x([0-9.]+)\), *([0-9.]+) MB/s, *([0-9.]+) MB/s' ]] || {
        printf '[Error] r%s L%s %s: no result line after 3 attempts; raw output follows\n%s\n' $r $l $v "$raw"; exit 1 }
      k=$v/$l
      ratio[$k]=$match[1]
      (( ${best_c[$k]:-0} < match[2] )) && best_c[$k]=$match[2]
      (( ${best_d[$k]:-0} < match[3] )) && best_d[$k]=$match[3]
      printf '  r%s L%s %s  x%s  %7s MB/s  %7s MB/s\n' $r $l $v $match[1] $match[2] $match[3]
    done
  done
done

{ printf 'level,variant,exe_bytes,ratio,best_comp_MBps,best_decomp_MBps,comp_vs_a_pct,decomp_vs_a_pct\n'
  printf '等級,版本,執行檔位元組,壓縮比,最佳壓縮MB/s,最佳解壓MB/s,壓縮相對a%%,解壓相對a%%\n'
  for l in $levels; do for v in $variants; do
    printf '%s,%s,%s,%s,%s,%s,%+.1f,%+.1f\n' $l $v ${bytes[$v]} ${ratio[$v/$l]} ${best_c[$v/$l]} ${best_d[$v/$l]} \
      $(( (best_c[$v/$l] / best_c[a/$l] - 1) * 100.0 )) $(( (best_d[$v/$l] / best_d[a/$l] - 1) * 100.0 ))
  done; done; } > "$OUTPUT_CSV2"
printf '\n[Info] zstd -b runs retried for a lost compression result / 因遺失壓縮結果而重試的次數: %s\n' $retries
printf '\n=== best of %s rounds / %s 輪最佳值 (%s) ===\n' $ROUNDS $ROUNDS "${OUTPUT_CSV2:t}"
csv2 -i "$OUTPUT_CSV2" -t -md
