#!/usr/bin/env zsh
# =====================================================================
# zip_parallel_speed.zsh -- how much faster is `-c --zip` on several threads, and what does it cost?
# zip_parallel_speed.zsh -- `-c --zip` 以多個執行緒壓縮快了多少，代價是什麼？
#
# 自 79fa438 起，ZIP 的每個成員各自由一個執行緒壓成 deflate 串流，再依序寫出；`-n` 是同時
# 壓縮的成員數，預設為核心數。本腳本以同一棵樹量每個 `-n` 的耗時、CPU 時間與最大記憶體，並
# 檢查每個 `-n` 的輸出位元組相同——速度若是靠改變輸出換來的，那就不是同一件事。
#
# Since 79fa438 every ZIP member is deflated by one thread and written in order; `-n` is how
# many members are compressed at once and defaults to the core count. This measures elapsed
# time, CPU time and peak memory for each `-n` on one tree, and checks that every `-n` gives
# the same bytes -- speed bought by changing the output would be a different thing.
#
# 量法 / Method:
#   * 逐輪交錯（每一輪把所有項目各跑一次），每個項目取耗時最短的那一輪。
#     Rounds are interleaved (each round runs every case once); a case's fastest round is kept.
#   * 輸出寫到 WORKDIR 的檔案，量完算 sha256 後刪除。WORKDIR 最好在記憶體檔案系統上。
#     Output goes to a file in WORKDIR, hashed and removed. WORKDIR is best RAM-backed.
#   * TZ=UTC：ZIP 檔頭的時間是本地時間，不設的話兩台機器的 sha256 無從比較。
#     TZ=UTC: ZIP headers hold local time, and without it two machines' sha256 cannot be compared.
#   * `-n 1` 就是改動之前的單一執行緒路徑，所以它同時是對照組。`--before BINARY` 可以另外
#     量一支改動之前的執行檔，確認這一點。
#     `-n 1` is the single-thread path from before the change, so it is also the control.
#     `--before BINARY` measures a binary from before the change as well, to confirm that.
#   * `--reference` 另外量機器上的 Info-ZIP `zip -r -6` 與 `bsdtar --format zip`（有的話）。
#     它們的輸出不是同樣的位元組，只比較耗時。
#     `--reference` also times Info-ZIP `zip -r -6` and `bsdtar --format zip` where present.
#     Their output is not the same bytes; only the time is compared.
#
# 用法 / Usage:
#   zip_parallel_speed.zsh run SWIFT_TAR PARENT NAME WORKDIR [--rounds N] [--before BINARY] [--reference]
#       壓 PARENT/NAME。每次執行印一行 `ZS <case> <round> <seconds> <user> <sys> <peak_kb> <bytes> <sha256>`，
#       最後印 `ZS-DONE`。不需要 csv2，所以能在 guest 內執行。
#       Packs PARENT/NAME. One `ZS ...` line per execution, then `ZS-DONE`. Needs no csv2, so it
#       runs inside a guest.
#   zip_parallel_speed.zsh record PLATFORM VERSION LINES_FILE [CSV2]
#       把 run 的輸出（可以是整份 console log）整理成每個項目一列，記入 csv2；同一平台的舊
#       紀錄會先移除。任何兩個 swift_tar 項目的 sha256 不同時以 1 結束。
#       Reduce the output of `run` (a whole console log will do) to one row per case in the
#       csv2, replacing that platform's earlier rows. Exits 1 when two swift_tar cases differ
#       in sha256.
#
# 結果見 zip_parallel_speed_output.txt 與 zip_parallel_speed.csv2。
# Results: zip_parallel_speed_output.txt and zip_parallel_speed.csv2.
# =====================================================================
set -u
SCRIPT_DIR=${0:A:h}
DEFAULT_CSV2="$SCRIPT_DIR/zip_parallel_speed.csv2"

usage() { sed -n '2,/^# ====.*$/p' "$0" | sed -n '/^# 用法/,$p' >&2; exit 2; }
(( $# >= 1 )) || usage
mode=$1; shift

case $mode in
run)
    (( $# >= 4 )) || usage
    ST=$1; PARENT=$2; NAME=$3; W=$4; shift 4
    rounds=3; before=""; reference=0
    while (( $# )); do
        case $1 in
            --rounds) rounds=$2; shift 2 ;;
            --before) before=$2; shift 2 ;;
            --reference) reference=1; shift ;;
            *) usage ;;
        esac
    done
    [[ -x $ST && -d $PARENT/$NAME ]] || { print -u2 -- "missing $ST or $PARENT/$NAME / 找不到"; exit 1 }
    mkdir -p "$W" || exit 1
    export TZ=UTC
    if whence sha256sum > /dev/null; then sha() { sha256sum "$1" | cut -c1-64 }; else sha() { shasum -a 256 "$1" | cut -c1-64 }; fi
    if whence nproc > /dev/null; then cores=$(nproc); else cores=$(getconf _NPROCESSORS_ONLN); fi
    print -r -- "ZS-INFO cores=$cores rounds=$rounds version=$("$ST" --version | head -1) files=$(find "$PARENT/$NAME" -type f | wc -l | tr -d ' ')"

    # one CASE COMMAND... -- the command must write $W/out.zip. / 指令必須寫出 $W/out.zip。
    one() {
        local name=$1; shift
        rm -f "$W/out.zip"
        local TIMEFMT='%E %U %S %M'
        { time "$@" > "$W/stdout.txt" 2> "$W/stderr.txt" } 2> "$W/time.txt"
        local rc=$?
        if (( rc != 0 )) || [[ ! -s $W/out.zip ]]; then
            print -r -- "ZS-FAIL $name rc=$rc $(head -1 "$W/stderr.txt" | cut -c1-120)"; return
        fi
        local t=(${=$(tail -1 "$W/time.txt")})
        print -r -- "ZS $name $round ${t[1]%s} ${t[2]%s} ${t[3]%s} ${t[4]} $(wc -c < "$W/out.zip" | tr -d ' ') $(sha "$W/out.zip")"
    }
    threads=(1 2 4 8 16)
    (( ${threads[(Ie)$cores]} )) || threads+=($cores)
    for (( round = 1; round <= rounds; round++ )); do
        for n in ${(on)threads}; do
            (( n <= cores * 4 )) || continue
            one "n$n" "$ST" -c --zip -n $n -f "$W/out.zip" -C "$PARENT" "$NAME"
        done
        one default "$ST" -c --zip -f "$W/out.zip" -C "$PARENT" "$NAME"
        one unsorted "$ST" -c --zip --zip-unsorted -f "$W/out.zip" -C "$PARENT" "$NAME"
        [[ -n $before ]] && one before "$before" -c --zip -f "$W/out.zip" -C "$PARENT" "$NAME"
        if (( reference )); then
            whence zip > /dev/null && ( cd "$PARENT" && one ref-infozip zip -r -6 -q "$W/out.zip" "$NAME" )
            whence bsdtar > /dev/null && one ref-bsdtar bsdtar -c --format zip -f "$W/out.zip" -C "$PARENT" "$NAME"
        fi
    done
    rm -f "$W/out.zip" "$W/stdout.txt" "$W/stderr.txt" "$W/time.txt"
    print -r -- "ZS-DONE"
    ;;

record)
    (( $# == 3 || $# == 4 )) || usage
    plat=$1; ver=$2; lines=$3; out=${4:-$DEFAULT_CSV2}
    grep -a -q '^ZS-DONE' "$lines" || { print -u2 -- "no ZS-DONE in $lines: the run did not finish / run 沒有跑完"; exit 1 }
    if grep -a -q '^ZS-FAIL' "$lines"; then grep -a '^ZS-FAIL' "$lines" >&2; exit 1; fi
    if [[ ! -f $out ]]; then
        print -r -- "platform,swift_tar_version,case,rounds,seconds,user_seconds,sys_seconds,peak_mb,speedup_vs_n1,bytes,sha256" > "$out"
        print -r -- "平台,版本戳,項目,輪數,耗時秒,使用者秒,系統秒,最大記憶體MB,相對n1的倍數,位元組,sha256" >> "$out"
    fi
    # Drop this platform's earlier records, last first so the numbering stays valid.
    # 先移除這個平台的舊紀錄，由後往前刪，編號才不會跑掉。
    n=$(csv2 -r -i "$out" | wc -l | tr -d ' ')
    for (( r = n; r >= 1; r-- )); do
        [[ $(csv2 -get $r:1 -i "$out") == $plat ]] && { csv2 -delete $r -i "$out" --in-place || exit 1 }
    done
    # Keep each case's fastest round. / 每個項目留下最快的那一輪。
    typeset -A best user sys peak bytes hash count; typeset -a order
    grep -a '^ZS ' "$lines" | tr -d '\r' | while read -r tag name round secs u s kb size digest; do
        (( ${+best[$name]} )) || order+=($name)
        count[$name]=$(( ${count[$name]:-0} + 1 ))
        if (( ! ${+best[$name]} )) || (( secs < ${best[$name]} )); then
            best[$name]=$secs; user[$name]=$u; sys[$name]=$s; peak[$name]=$kb; bytes[$name]=$size; hash[$name]=$digest
        fi
    done
    (( ${+best[n1]} )) || { print -u2 -- "no n1 case in $lines / 沒有 n1 項目"; exit 1 }
    bad=0
    for name in $order; do
        speedup=$(printf '%.2f' $(( ${best[n1]} / ${best[$name]} )))
        mb=$(printf '%.0f' $(( ${peak[$name]} / 1024.0 )))
        csv2 -append "$plat,$ver,$name,${count[$name]},${best[$name]},${user[$name]},${sys[$name]},$mb,$speedup,${bytes[$name]},${hash[$name]}" -i "$out" --in-place || exit 1
        # Sorted swift_tar cases must all be the same bytes; unsorted and the references are
        # other archives. / 排序的 swift_tar 項目必須全部是相同的位元組；unsorted 與參照是別的封存。
        if [[ $name == (n<->|default|before) && ${hash[$name]} != ${hash[n1]} ]]; then
            print -r -- "DIFFERENT     $name: sha256 is not that of n1 / 與 n1 不同"; bad=1
        fi
    done
    print -r -- "recorded ${#order} cases for $plat in $out / 已記錄 $plat 的 ${#order} 項"
    (( bad == 0 )) && print -r -- "same bytes for every -n / 每個 -n 的位元組都相同"
    exit $bad
    ;;
*) usage ;;
esac
