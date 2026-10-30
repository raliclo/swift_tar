#!/usr/bin/env zsh
# win_clang_deps.zsh -- compare swift_tar.exe builds whose C dependencies (zstd, zlib, libarchive) were compiled differently.
# win_clang_deps.zsh -- 比較 C 相依（zstd、zlib、libarchive）以不同編譯器建置的數個 swift_tar.exe。
#
#   zsh verifications/win_clang_deps.zsh CORPUS_DIR LABEL=EXE [LABEL=EXE ...]
#   ROUNDS=5 WORK=C:/Users/$USER/tmp/wcd zsh verifications/win_clang_deps.zsh ../claw-code \
#       msvc=C:/Users/$USER/tmp/zclang/swift_tar.msvc-zstd.exe clang=release/swift_tar.exe
#   zsh verifications/win_clang_deps.zsh --help
#
# Six operations per binary, interleaved across binaries, best (shortest wall time) of ROUNDS:
#   tgz-c  -c -z           tgz-d  --cat of that .tgz   (zlib deflate / inflate)
#   zst-c  -c --zstd (9)   zst-d  --cat of that .tzst  (libzstd at swift_tar's default level)
#   zip-c  -c --zip        zip-x  -x of that .zip      (libarchive + zlib; -x writes files)
# --cat output goes to /dev/null, so tgz-d and zst-d time the codec, not the disk. zip-x does
# write the tree (into WORK, removed after each run, removal not timed): ZIP has no --cat.
# Each binary's archives are also compared byte for byte with the first binary's: a compiler
# change must not change what is written. MB/s is corpus logical bytes (tar size) per second.
# 每個執行檔六項操作，各執行檔交錯，取 ROUNDS 輪中牆鐘最短者：
#   tgz-c／tgz-d（zlib）、zst-c／zst-d（libzstd，swift_tar 預設等級 9）、zip-c／zip-x（libarchive + zlib）。
# --cat 的輸出丟到 /dev/null，因此 tgz-d 與 zst-d 量的是 codec 而非磁碟。zip-x 會真的寫出檔案（寫到
# WORK，每次後刪除，刪除不計時）：ZIP 沒有 --cat。每個執行檔產生的封存也與第一個執行檔逐位元組比對：
# 換編譯器不得改變寫出的內容。MB/s 以語料 logical bytes（tar 大小）除以秒數。
#
# Output: win_clang_deps_output.txt and win_clang_deps.csv2 next to this script.
# 輸出：本腳本旁的 win_clang_deps_output.txt 與 win_clang_deps.csv2。
set -uo pipefail
zmodload zsh/datetime || exit 1   # EPOCHREALTIME / 提供 EPOCHREALTIME
script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then sed -n '2,25p' "$script_path" | sed 's/^# \{0,1\}//'; exit 0; fi
(( $# >= 3 )) || { printf 'usage: %s CORPUS_DIR LABEL=EXE LABEL=EXE...  (--help)\n' "${script_path:t}" >&2; exit 2 }

SCRIPT_DIR=${script_path:h}
CORPUS=${1:A}; shift
ROUNDS=${ROUNDS:-5}
WORK=${WORK:-C:/Users/${USER:-$USERNAME}/tmp/wcd}
OUTPUT_TXT=$SCRIPT_DIR/win_clang_deps_output.txt
OUTPUT_CSV2=$SCRIPT_DIR/win_clang_deps.csv2
[[ -d $CORPUS ]] || { printf '[Error] corpus not found: %s\n' "$CORPUS" >&2; exit 1 }
typeset -a labels; typeset -A exe
for pair in "$@"; do
  [[ $pair == *=* ]] || { printf '[Error] expected LABEL=EXE, got %s\n' "$pair" >&2; exit 2 }
  l=${pair%%=*}; exe[$l]=${${pair#*=}:A}; labels+=($l)
  [[ -x ${exe[$l]} ]] || { printf '[Error] not executable: %s\n' "${exe[$l]}" >&2; exit 1 }
done
exec > >(tee "$OUTPUT_TXT") 2>&1

parent=${CORPUS:h} leaf=${CORPUS:t}
logical=$(tar --force-local -cf - -C "$parent" "$leaf" | wc -c)
cpu=$(MSYS2_ARG_CONV_EXCL='*' reg query 'HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0' /v ProcessorNameString \
      | tr -d '\r' | awk '/ProcessorNameString/ { sub(/.*REG_SZ +/, ""); sub(/ +$/, ""); print }')
printf '[Info] date: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf '[Info] os: %s   cpu: %s   cores: %s\n' "$(uname -sr)" "$cpu" "$(nproc)"
printf '[Info] corpus: %s (%s files, tar %s bytes)   rounds: %s\n' "$CORPUS" "$(find "$CORPUS" -type f | wc -l)" "$logical" "$ROUNDS"
for l in $labels; do printf '[Info] %-8s %s  %s bytes  %s\n' "$l" "${exe[$l]}" "$(wc -c < "${exe[$l]}")" "$("${exe[$l]}" --version)"; done

rm -rf -- "$WORK"; mkdir -p "$WORK" || exit 1
ops=(tgz-c tgz-d zst-c zst-d zip-c zip-x)
typeset -A best
# run LABEL OP: one timed operation; prints seconds. / 一次計時操作，印出秒數。
run() {
  local l=$1 op=$2 x=${exe[$1]} d=$WORK/$1 t0 t1 rc
  mkdir -p "$d"
  t0=$EPOCHREALTIME
  case $op in
    tgz-c) "$x" -c -z -f "$d/a.tgz" -C "$parent" "$leaf" ;;
    tgz-d) "$x" --cat -f "$d/a.tgz" > /dev/null ;;
    zst-c) "$x" -c --zstd -f "$d/a.tzst" -C "$parent" "$leaf" ;;
    zst-d) "$x" --cat -f "$d/a.tzst" > /dev/null ;;
    zip-c) "$x" -c --zip -f "$d/a.zip" -C "$parent" "$leaf" ;;
    zip-x) mkdir -p "$d/x" && "$x" -x -f "$d/a.zip" -C "$d/x" ;;
  esac
  rc=$?; t1=$EPOCHREALTIME
  [[ $op == zip-x ]] && rm -rf -- "$d/x"
  (( rc == 0 )) || { printf '[Error] %s %s exited %s\n' "$l" "$op" $rc >&2; return 1 }
  printf '%.3f' $(( t1 - t0 ))
}

printf '\n=== interleaved runs (seconds) / 交錯執行（秒） ===\n'
for (( r = 1; r <= ROUNDS; r++ )); do
  for op in $ops; do
    for l in $labels; do
      s=$(run $l $op) || exit 1
      k=$l/$op
      [[ -z ${best[$k]:-} ]] || (( s < best[$k] )) && best[$k]=$s
      printf '  r%s %-6s %-8s %8s s\n' $r $op $l $s
    done
  done
  # Byte-for-byte check after round 1, while the archives are fresh. / 第 1 輪後逐位元組比對。
  if (( r == 1 )); then
    printf '  -- archives vs %s / 與 %s 的封存比對 --\n' $labels[1] $labels[1]
    for l in ${labels:1}; do for f in a.tgz a.tzst a.zip; do
      if cmp -s "$WORK/$labels[1]/$f" "$WORK/$l/$f"; then printf '  %-8s %-7s identical (%s bytes)\n' $l $f "$(wc -c < "$WORK/$l/$f")"
      else printf '  %-8s %-7s DIFFERS: %s vs %s bytes\n' $l $f "$(wc -c < "$WORK/$labels[1]/$f")" "$(wc -c < "$WORK/$l/$f")"; fi
    done; done
  fi
done

{ printf 'op,binary,best_seconds,MBps,vs_%s_pct\n' $labels[1]
  printf '操作,執行檔,最佳秒數,MB/s,相對%s%%\n' $labels[1]
  for op in $ops; do for l in $labels; do
    printf '%s,%s,%s,%.1f,%+.1f\n' $op $l ${best[$l/$op]} $(( logical / 1e6 / best[$l/$op] )) \
      $(( (best[$labels[1]/$op] / best[$l/$op] - 1) * 100.0 ))
  done; done; } > "$OUTPUT_CSV2"
printf '\n=== best of %s rounds / %s 輪最佳值 (%s; +%% = faster than %s) ===\n' $ROUNDS $ROUNDS "${OUTPUT_CSV2:t}" $labels[1]
csv2 -i "$OUTPUT_CSV2" -t -md
rm -rf -- "$WORK"
