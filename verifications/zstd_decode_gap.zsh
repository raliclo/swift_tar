#!/bin/zsh
# =====================================================================
# zstd_decode_gap.zsh -- native 與 external zstd 的解壓差距，逐面向量測。
# zstd_decode_gap.zsh -- measure the native/external zstd decode gap, one facet at a time.
#
# 本檔不下結論，只產生足以下結論的數字。R50-Mac 第 3 節的頭兩版結論都是在數字不足時
# 寫出來的，且都被下一組量測推翻——每個 --mode 旗標對應的就是推翻它們的那一項證據。
#
# It does not conclude; it produces the numbers a conclusion needs. Two successive
# conclusions in R50-Mac section 3 were written without them and each was overturned by
# the next measurement. Every --mode below corresponds to one of those overturnings.
#
# 用法 / Usage:
#   verifications/zstd_decode_gap.zsh [--mode M]... [選項]
#
# 模式 / Modes（可重複；預設 --mode pipeline）:
#   --mode pipeline    native 對 external，完整解出與純解壓縮，拆出 real/user/sys。
#                      這是主表：user 相同而 sys 不同，代表差距在系統呼叫而非計算。
#                      native vs external, full extract and pure decompression, split into
#                      real/user/sys. Identical user with differing sys means the gap is
#                      syscalls, not computation.
#   --mode threads     掃描 -n。回答「zstd 解壓是否該調 -n」。
#                      Sweeps -n. Answers whether -n is worth tuning for zstd decode.
#   --mode syscall     以 time -l 的 page fault、block I/O 與 context switch 計數，
#                      指出 sys 時間的去向。不需 sudo，故任何機器都跑得起來。
#                      Page faults, block I/O and context switches from time -l, to say
#                      where sys time goes. No sudo, so it runs anywhere.
#   --mode chunk       以不同 --zstd-level 建檔並比較 frame 數與解壓成本。chunk 大小
#                      本身是編譯期常數（TAR_CHUNK_SIZE），無法由旗標調整，故此模式
#                      量的是「frame 數的影響」而非「chunk 大小的影響」——差別重要。
#                      Chunk size is a compile-time constant, so this measures the effect
#                      of frame count rather than of chunk size. The distinction matters.
#   --mode storage     同一組量測分別在 RAM disk 與實際磁碟上跑，顯示儲存層如何改變
#                      結論。**這一項曾經翻轉勝負**：內接碟上 external 快，RAM disk 上
#                      native 快。
#                      Runs the same comparison on a RAM disk and on real storage. This
#                      one has reversed the verdict: external wins on the internal SSD,
#                      native wins on the RAM disk.
#   --mode all         以上全部 / everything above
#
# 選項 / Options:
#   --corpus PATH      語料目錄，預設 ../claw-code / corpus directory
#   --reps N           每點的重複次數，預設 5 / repetitions per point
#   --ram-gb N         RAM disk 大小，預設 3 / RAM disk size
#   --out PATH         另存一份輸出，預設 verifications/zstd_decode_gap.txt。量測的數字
#                      若只留在終端機裡，下一次就只能重跑；存檔才能與後續比對。
#                      Also write the output to a file. Numbers left only in a terminal
#                      can only be re-earned by rerunning; a file can be diffed later.
#   --no-ramdisk       不建 RAM disk，直接用實際磁碟（storage 模式會自行忽略此旗標）
#                      Skip the RAM disk; --mode storage ignores this since it needs both.
#   -h, --help         顯示此說明 / show this
#
# 量測方法上的四件事，都是踩過才知道的：
#
#   1. **解出目標必須是 RAM disk**（除非刻意要量儲存層）。反覆在內接碟上寫入 1.3 GB
#      會讓後續量測單調劣化（實測 1.74 → 3.08 → 5.45 → 5.99 秒），最小值於是挑到序列
#      早期的那次——先量的設定看起來永遠比較快。
#   2. **必須交錯。** 把 A 跑完再跑 B，兩者會落在不同的機器狀態上。
#   3. **必須看 user 與 sys，不只看 real。** real 只說「誰比較慢」；user/sys 才說
#      「慢在計算還是慢在系統呼叫」，而那兩者要改的東西完全不同。
#   4. **不要寫 `2>&1 >/dev/null`。** zsh 的 MULTIOS 不照 POSIX 順序處理它，`--cat` 的
#      整條 tar 串流會漏進管線，計時因而回傳空值——而表格其餘各列仍有數字，看起來像是
#      「那兩列沒跑」而不是「量測壞了」。
#
# Four things about method, each learned the hard way: extract to a RAM disk or repeated
# large writes make every later measurement slower; interleave; read user and sys, not just
# real; and never write `2>&1 >/dev/null` in zsh, where MULTIOS does not apply it in POSIX
# order and the timing silently returns nothing while the rest of the table still prints.
# =====================================================================
set -uo pipefail

HERE="${0:A:h}"
ST="${SWIFT_TAR:-${HERE:h}/release/swift_tar}"
CORPUS="${HERE:h:h}/claw-code"
REPS=5
RAMGB=3
USE_RAM=1
OUTFILE=""
typeset -a MODES

while (( $# )); do
    case "$1" in
        --mode)       shift; MODES+=("${1:?--mode needs a value}") ;;
        --corpus)     shift; CORPUS="${1:?--corpus needs a path}" ;;
        --reps)       shift; REPS="${1:?--reps needs a number}" ;;
        --ram-gb)     shift; RAMGB="${1:?--ram-gb needs a number}" ;;
        --no-ramdisk) USE_RAM=0 ;;
        --out)        shift; OUTFILE="${1:?--out needs a path}" ;;
        -h|--help)    sed -n '2,64p' "${0:A}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print -ru2 -- "unknown option: $1 (try --help)"; exit 2 ;;
    esac
    shift
done

# 終端機與檔案同時收。用 tee 而非把每個 print 都導兩次：後者漏一行不會有人發現。
# Both terminal and file, via tee rather than duplicating every print: a missed line in
# the second form is invisible.
OUTFILE="${OUTFILE:-${HERE}/zstd_decode_gap.txt}"
exec > >(tee "$OUTFILE") 2>&1
(( ${#MODES} )) || MODES=(pipeline)
# `${MODES[(r)all]}` 在無命中時於 `set -u` 之下會中止腳本，故加上 `:-` 的預設值。
# Without the `:-` default this aborts under `set -u` when nothing matches.
[[ "${MODES[(r)all]:-}" == all ]] && MODES=(pipeline threads syscall chunk storage)

[[ -x "$ST" ]]     || { print -ru2 -- "no swift_tar at $ST — run compile_tar.zsh"; exit 1 }
[[ -d "$CORPUS" ]] || { print -ru2 -- "no corpus at $CORPUS"; exit 1 }
for c in zstd tar; do
    command -v $c >/dev/null 2>&1 || { print -ru2 -- "missing $c"; exit 1 }
done

print -- "[Info] date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
print -- "[Info] os: $(command -v sw_vers >/dev/null 2>&1 && echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))" || uname -sr)"
print -- "[Info] machine: $(uname -m), $(sysctl -n hw.ncpu 2>/dev/null || nproc) cpus"
print -- "[Info] swift_tar: $("$ST" --version 2>/dev/null | head -1)"
print -- "[Info] corpus: $CORPUS ($(du -sm "$CORPUS" | cut -f1) MB, $(find "$CORPUS" -type f | wc -l | tr -d ' ') files)"
print -- "[Info] modes: ${MODES[*]}   reps: $REPS"

WORK=$(mktemp -d)
RAM_MOUNT=""
cleanup() {
    [[ -n "$RAM_MOUNT" && -d "$RAM_MOUNT" ]] && diskutil eject "$RAM_MOUNT" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

make_ramdisk() {
    [[ "$(uname -s)" == Darwin ]] || { print -- "[Warning] RAM disk is macOS-only here"; return 1 }
    local dev
    dev=$(hdiutil attach -nomount "ram://$(( RAMGB * 1024 * 1024 * 1024 / 512 ))" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$dev" ]] || return 1
    diskutil eraseVolume APFS zdgRAM "$dev" >/dev/null 2>&1 || return 1
    RAM_MOUNT=/Volumes/zdgRAM
    return 0
}

# `/usr/bin/time -l` 把報告寫到 stderr。stdout 與 stderr 各自導向檔案，不用 `2>&1 >…`
# ——見檔頭第 4 點。
# time -l reports on stderr. Each stream goes to its own file; see note 4 in the header.
#
# 實測（zsh 5.9 / macOS 27.0，三種形狀）：
#   zsh  「cmd 2>&1 >/dev/null | cat」        → ERR 與 OUT 皆出現   ← 洩漏
#   bash 同一形狀                              → 只有 ERR
#   zsh  同一形狀 + unsetopt multios           → 只有 ERR
#   zsh  「cmd 2>&1 >/dev/null」（無管線）      → 只有 ERR
# 故成因是 MULTIOS，且**只在管線中**發生：stdout 本已接到管線，`>/dev/null` 被當成
# 追加一個輸出而非取代。與平台無關，是 shell 差異。
# Measured in three shapes: the leak appears only inside a pipeline, only under zsh, and
# only with MULTIOS on. It is a shell difference, not a platform one.
TIMEOUT_ERR="$WORK/.time"
timed() {  # <command...> -> "real user sys"
    /usr/bin/time -l "$@" >/dev/null 2>"$TIMEOUT_ERR"
    grep -E '[0-9.]+ +real' "$TIMEOUT_ERR" | head -1 | awk '{print $1, $3, $5}'
}
timed_field() {  # <欄位關鍵字> — 讀上一次 timed 的 time -l 明細
    grep -i -- "$1" "$TIMEOUT_ERR" 2>/dev/null | head -1 | awk '{print $1}'
}

build_archives() {
    print -- ""
    print -- "=== 建立兩種封存（同為 level 9）/ building both archives at level 9 ==="
    tar -cf - -C "${CORPUS:h}" "${CORPUS:t}" | zstd -9 -q -o "$WORK/ext.tar.zst" -f 2>/dev/null
    "$ST" -c --zstd --zstd-level 9 -f "$WORK/nat.tar.zst" -C "${CORPUS:h}" "${CORPUS:t}" 2>/dev/null
    for f in ext nat; do
        printf '  %-4s %8.1f MB  frames %s\n' "$f" \
            "$(( $(stat -f%z "$WORK/$f.tar.zst" 2>/dev/null || stat -c%s "$WORK/$f.tar.zst") / 1048576.0 ))" \
            "$(zstd -l "$WORK/$f.tar.zst" 2>&1 | tail -1 | awk '{print $1}')"
    done
}

# --- mode: pipeline ------------------------------------------------------
mode_pipeline() {  # <解出目標> <標題>
    local out=$1 title=$2
    typeset -A bR bU bS
    for k in nat_full ext_full nat_cat ext_cat; do bR[$k]=99999; bU[$k]=0; bS[$k]=0; done
    local i pair k
    for (( i = 1; i <= REPS; i++ )); do
        for pair in nat ext; do
            rm -rf "$out"; mkdir -p "$out"
            if [[ $pair == nat ]]; then
                set -- $(timed "$ST" -x -f "$WORK/nat.tar.zst" -C "$out")
            else
                set -- $(timed sh -c "zstd -d -c '$WORK/ext.tar.zst' | (cd '$out' && tar -xf -)")
            fi
            k="${pair}_full"
            (( $# == 3 )) || { print -ru2 -- "[Error] no timing for $k"; exit 1 }
            if (( $1 < bR[$k] )); then bR[$k]=$1; bU[$k]=$2; bS[$k]=$3; fi

            if [[ $pair == nat ]]; then
                set -- $(timed "$ST" --cat -f "$WORK/nat.tar.zst")
            else
                set -- $(timed zstd -d -c "$WORK/ext.tar.zst")
            fi
            k="${pair}_cat"
            (( $# == 3 )) || { print -ru2 -- "[Error] no timing for $k"; exit 1 }
            if (( $1 < bR[$k] )); then bR[$k]=$1; bU[$k]=$2; bS[$k]=$3; fi
        done
    done
    rm -rf "$out"
    print -- ""
    print -- "=== pipeline${title:+ / $title}（每列取 real 最小的那一次）==="
    printf '  %-16s %7s %7s %7s %8s\n' "" real user sys CPU/wall
    local lbl
    for k in nat_full ext_full nat_cat ext_cat; do
        case $k in
            nat_full) lbl="native 解出" ;; ext_full) lbl="external 解出" ;;
            nat_cat)  lbl="native --cat" ;; ext_cat) lbl="external -d" ;;
        esac
        printf '  %-16s %7.2f %7.2f %7.2f %8.2f\n' "$lbl" \
            "${bR[$k]}" "${bU[$k]}" "${bS[$k]}" "$(( (bU[$k] + bS[$k]) / bR[$k] ))"
    done
}

# --- mode: threads -------------------------------------------------------
mode_threads() {
    local out=$1
    print -- ""
    print -- "=== threads：掃描 -n / sweeping -n ==="
    printf '  %-5s %-34s %8s\n' -n "各次（秒）" 最小
    local n i s best line
    typeset -A bestOf
    for n in 1 2 3 4 8 16 40; do
        best=99999; line=""
        for (( i = 1; i <= REPS; i++ )); do
            rm -rf "$out"; mkdir -p "$out"
            set -- $(timed "$ST" -x -n $n -f "$WORK/nat.tar.zst" -C "$out")
            (( $# == 3 )) || { print -ru2 -- "[Error] no timing at -n $n"; exit 1 }
            line="$line $1"; (( $1 < best )) && best=$1
        done
        bestOf[$n]=$best
        printf '  %-5s %-34s %8.2f\n' "$n" "$line" "$best"
    done
    rm -rf "$out"
    print -- "  --- 相對 -n 1 / relative to -n 1 ---"
    for n in 2 3 4 8 16 40; do
        printf '  n%-3s %+.1f%%\n' "$n" "$(( (bestOf[$n] - bestOf[1]) / bestOf[1] * 100 ))"
    done
}

# --- mode: syscall -------------------------------------------------------
mode_syscall() {
    local out=$1
    print -- ""
    print -- "=== syscall：sys 時間的去向 / where sys time goes ==="
    print -- "  取自 time -l，無需 sudo。核心事實：兩邊 user 相近時，差距落在下列計數上。"
    print -- "  From time -l, no sudo. When user is comparable, the gap lives in these counts."
    printf '  %-16s %10s %10s %12s %12s\n' "" sys秒 page-faults vol-ctx-sw invol-ctx-sw
    local pair lbl
    for pair in nat ext; do
        rm -rf "$out"; mkdir -p "$out"
        if [[ $pair == nat ]]; then
            lbl="native 解出"
            set -- $(timed "$ST" -x -f "$WORK/nat.tar.zst" -C "$out")
        else
            lbl="external 解出"
            set -- $(timed sh -c "zstd -d -c '$WORK/ext.tar.zst' | (cd '$out' && tar -xf -)")
        fi
        printf '  %-16s %10s %10s %12s %12s\n' "$lbl" "$3" \
            "$(timed_field 'page reclaims')" \
            "$(timed_field 'voluntary context switches')" \
            "$(timed_field 'involuntary context switches')"
    done
    rm -rf "$out"
    print -- "  注意：external 是兩個行程，其 time -l 只涵蓋外層 sh，故其計數偏低。"
    print -- "  Note: external is two processes and time -l covers only the outer sh, so its"
    print -- "  counts understate the total. Compare shapes, not absolute values."
}

# --- mode: chunk ---------------------------------------------------------
mode_chunk() {
    print -- ""
    print -- "=== chunk：frame 數的影響 / the effect of frame count ==="
    print -- "  TAR_CHUNK_SIZE 是編譯期常數，旗標無從調整，故此處改以 --zstd-level 觀察"
    print -- "  「frame 數固定、壓縮量改變」時的成本，用以區分兩者。"
    print -- "  Chunk size is compile-time, so this varies --zstd-level instead: frame count"
    print -- "  stays fixed while the compressed volume changes, separating the two effects."
    printf '  %-8s %10s %8s %10s %10s\n' level 大小MB frames cat秒 sys秒
    local lv
    for lv in 1 9 19; do
        "$ST" -c --zstd --zstd-level $lv -f "$WORK/lv.tar.zst" -C "${CORPUS:h}" "${CORPUS:t}" 2>/dev/null
        set -- $(timed "$ST" --cat -f "$WORK/lv.tar.zst")
        printf '  %-8s %10.1f %8s %10s %10s\n' "$lv" \
            "$(( $(stat -f%z "$WORK/lv.tar.zst" 2>/dev/null || stat -c%s "$WORK/lv.tar.zst") / 1048576.0 ))" \
            "$(zstd -l "$WORK/lv.tar.zst" 2>&1 | tail -1 | awk '{print $1}')" "$1" "$3"
    done
    rm -f "$WORK/lv.tar.zst"
}

# --- mode: storage -------------------------------------------------------
mode_storage() {
    print -- ""
    print -- "=== storage：儲存層如何改變結論 / how storage changes the verdict ==="
    if [[ -z "$RAM_MOUNT" ]] && ! make_ramdisk; then
        print -- "  skip 無法建立 RAM disk，本模式需要兩者對照 / needs both, RAM disk unavailable"
        return
    fi
    mode_pipeline "$RAM_MOUNT/out" "RAM disk"
    mode_pipeline "$WORK/out" "實際磁碟 / real storage"
    print -- ""
    print -- "  兩張表的勝負若不同，代表該差距由儲存層而非 codec 決定——這正是先前發生過的事。"
    print -- "  If the two tables disagree on the winner, the gap belongs to the storage layer"
    print -- "  rather than to the codec. That has already happened once."
}

# --- 執行 / run ----------------------------------------------------------
build_archives

DEST="$WORK/out"
if (( USE_RAM )) && [[ ${MODES[(r)storage]:-} != storage ]]; then
    if make_ramdisk; then
        DEST="$RAM_MOUNT/out"
        print -- "[Info] extracting to RAM disk ${RAMGB}GB"
    else
        print -- "[Warning] RAM disk unavailable; figures carry disk noise"
    fi
fi

for m in $MODES; do
    case $m in
        pipeline) mode_pipeline "$DEST" "" ;;
        threads)  mode_threads  "$DEST" ;;
        syscall)  mode_syscall  "$DEST" ;;
        chunk)    mode_chunk ;;
        storage)  mode_storage ;;
        *) print -ru2 -- "unknown mode: $m (pipeline|threads|syscall|chunk|storage|all)"; exit 2 ;;
    esac
done

print -- ""
print -- "=== 判讀 / how to read this ==="
print -- "  user 相同、sys 不同    → 計算量相同，差在系統呼叫；平行化不會有幫助"
print -- "  user 不同              → 計算量本身有差"
print -- "  CPU/wall 明顯不同       → 才是平行度的差異"
print -- "  RAM disk 與磁碟結論不同 → 該差距屬於儲存層，不屬於 codec"
print -- "  same user, different sys -> same computation; parallelising will not close it"
print -- "  different user           -> the computation itself differs"
print -- "  different CPU/wall       -> only then is it about parallelism"
print -- "  RAM disk and disk disagree -> the gap belongs to storage, not to the codec"
