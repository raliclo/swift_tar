#!/usr/bin/env zsh
# =====================================================================
# cross_platform_bytes.zsh -- is swift_tar's output byte-identical across platforms?
# cross_platform_bytes.zsh -- swift_tar 的輸出在各平台之間是否逐位元組相同？
#
# 同一棵樹在每個平台各打包一次，記下每個產物的 sha256，再逐項比較。2026-10-13 第一次這樣做
# 時找到兩件事：`--gzip` 的檔頭帶著建置主機的 OS 位元組（已修正），以及 `--zip` 的成員順序
# 跟著檔案系統的 readdir 順序走（見 todo/todo.md）。兩者的輸出大小在兩個平台上都相同，只有
# 比對內容才看得出來。
#
# The same tree is packed once per platform, the sha256 of every artifact is recorded, and
# the records are compared case by case. The first time this was done, on 2026-10-13, it
# found two things: `--gzip` carried the build host's OS byte in its header (fixed), and
# `--zip` stores members in the filesystem's readdir order (see todo/todo.md). In both, the
# output had the same size on both platforms; only comparing content showed it.
#
# 輸入必須相同，輸出才可能相同 / The inputs have to match before the outputs can:
#   * 擁有者。tar 檔頭記 uid 與 gid；以 root 解開的樹是 0:0。run 模式以 root 執行時會把
#     語料 chown 成 501:20，其他情況下由呼叫者負責。
#     Ownership. A tar header records uid and gid, and a tree extracted as root is 0:0.
#     `run` chowns the corpus to 501:20 when it runs as root; otherwise that is the caller's job.
#   * 時區。ZIP 檔頭的時間是本地時間，所以 run 模式一律設 TZ=UTC。
#     Time zone. ZIP headers hold local time, so `run` sets TZ=UTC throughout.
#   * 語料本身。每個平台都要從同一份封存檔解開，mtime 才會一致；不要封存當場建立的目錄。
#     The corpus. Extract it from the same archive on every platform so mtimes agree, and
#     do not archive a directory that was created on the spot.
#
# 用法 / Usage:
#   cross_platform_bytes.zsh prepare SWIFT_TAR AUXDIR
#       建立 AUXDIR/overlay.tar（-u 用的變更）與 AUXDIR/key.bin。只做一次，兩個平台共用。
#       Make AUXDIR/overlay.tar (the change -u will pick up) and AUXDIR/key.bin. Once;
#       both platforms use the same two files.
#   cross_platform_bytes.zsh run SWIFT_TAR WORKDIR AUXDIR
#       WORKDIR/src/claw-code 必須是語料，WORKDIR 應在記憶體檔案系統上。每個產物印一行
#       `XC <case> <rc> <bytes> <sha256>`。不需要 csv2，所以能在 guest 內執行。若
#       AUXDIR/foreign.enc 存在，會以它驗證「另一個平台加密的檔案解得開」。
#       WORKDIR/src/claw-code must be the corpus, and WORKDIR should be RAM-backed. Prints
#       one `XC <case> <rc> <bytes> <sha256>` line per artifact. Needs no csv2, so it runs
#       inside a guest. If AUXDIR/foreign.enc exists it is used to check that a file
#       encrypted on the other platform decrypts here.
#   cross_platform_bytes.zsh record PLATFORM VERSION LINES_FILE [CSV2]
#       把 run 的輸出（可以是整份 console log）記入 csv2；同一平台的舊紀錄會先移除。
#       Record the output of `run` (a whole console log will do) in the csv2, replacing
#       that platform's earlier records.
#   cross_platform_bytes.zsh compare PLATFORM_A PLATFORM_B [CSV2]
#       逐項比較。有任何預期相同的項目不同、或預期不同的項目相同時，以 1 結束。
#       Compare case by case. Exits 1 when a case expected to match differs, or one
#       expected to differ matches.
#
# 語料 / Corpus: claw-code（~/proj/lzfse2/claw-code）。下方 run 模式用到的子目錄與檔名是它的。
# The subdirectories and file names in `run` below belong to it.
# =====================================================================
set -u
SCRIPT_DIR=${0:A:h}
DEFAULT_CSV2="$SCRIPT_DIR/cross_platform_bytes.csv2"

usage() { sed -n '2,/^# ====.*$/p' "$0" | sed -n '/^# 用法/,$p' >&2; exit 2; }
(( $# >= 1 )) || usage
mode=$1; shift

if whence sha256sum > /dev/null; then sha() { sha256sum | cut -c1-64 }; else sha() { shasum -a 256 | cut -c1-64 }; fi

case $mode in
prepare)
    (( $# == 2 )) || usage
    ST=$1; AUX=$2
    mkdir -p "$AUX/ov/claw-code/docs" || exit 1
    print -r -- "changed on purpose for the -u comparison" > "$AUX/ov/claw-code/docs/container.md"
    print -r -- "a new member" > "$AUX/ov/claw-code/docs/XC_NEW.md"
    "$ST" -c -f "$AUX/overlay.tar" -C "$AUX/ov" claw-code/docs || exit 1
    head -c 64 /dev/urandom > "$AUX/key.bin" || exit 1
    print -r -- "prepared / 已備妥: $AUX/overlay.tar $AUX/key.bin"
    ;;

run)
    (( $# == 3 )) || usage
    zmodload zsh/stat
    ST=$1; W=$2; AUX=$3
    export TZ=UTC
    [[ -d $W/src/claw-code ]] || { print -u2 -- "no corpus at $W/src/claw-code / 找不到語料"; exit 1 }
    [[ -f $AUX/overlay.tar && -f $AUX/key.bin ]] || { print -u2 -- "run prepare first / 請先執行 prepare"; exit 1 }
    [[ $EUID == 0 ]] && chown -R 501:20 "$W/src/claw-code"

    # emit CASE RC FILE -- a missing or empty file is reported as such, never as a hash of nothing.
    # emit CASE RC FILE——檔案不存在或為空時照實回報，不會算出「空內容的雜湊」。
    emit() {
        if [[ -s $3 ]]; then print -r -- "XC $1 $2 $(wc -c < $3 | tr -d ' ') $(sha < $3)"
        else print -r -- "XC $1 $2 0 no-output"; fi
    }
    mt() { zstat -L -F '%s.%N' +mtime "$1" }

    # 1. Every built-in codec and both ZIP forms, whole corpus. --lzip is left out on
    #    purpose: it runs whatever `lzip` is on PATH, so its bytes belong to that program
    #    and its version, not to swift_tar, and a guest without it has nothing to compare.
    # 1. 每種內建 codec 與兩種 ZIP，整份語料。刻意不含 --lzip：它執行的是 PATH 上的 `lzip`，
    #    輸出的位元組屬於那支程式與它的版本，不屬於 swift_tar；沒有裝它的 guest 也無從比較。
    for c in "none:" "zstd3:--zstd --zstd-level 3" "gzip:--gzip" "lzfse:--other3-fast" \
             "bzip2:--bzip2" "xz:--xz" "lz4:--lz4" "zip:--zip" "zip64:--zip64"; do
        name=${c%%:*}; flags=(${=c#*:}); rm -f $W/a.bin
        "$ST" -c -f $W/a.bin $flags -C $W/src claw-code 2> $W/err.txt; rc=$?
        emit $name $rc $W/a.bin
        (( rc )) && print -r -- "XC-NOTE $name: $(head -1 $W/err.txt | cut -c1-160)"
    done
    rm -f $W/a.bin

    # 2. -r, -u and --delete on a plain tar. The change -u picks up comes from overlay.tar,
    #    so the changed file, the new file and their mtimes are the same on every platform.
    # 2. 對純 tar 做 -r、-u 與 --delete。-u 要撿的變更來自 overlay.tar，所以被改的檔案、
    #    新增的檔案與它們的 mtime 在每個平台上都相同。
    U=$W/u.tar; rm -f $U
    "$ST" -c -f $U -C $W/src claw-code/docs claw-code/tests; emit tar-create $? $U
    "$ST" -r -f $U -C $W/src claw-code/assets; emit tar-append-r $? $U
    "$ST" -x -f $AUX/overlay.tar -C $W/src; orc=$?
    [[ $EUID == 0 ]] && chown -R 501:20 "$W/src/claw-code/docs"
    print -r -- "$(mt $W/src/claw-code/docs) $(mt $W/src/claw-code/docs/container.md) $(mt $W/src/claw-code/docs/XC_NEW.md) $(zstat +uid $W/src/claw-code/docs/XC_NEW.md):$(zstat +gid $W/src/claw-code/docs/XC_NEW.md)" > $W/state.txt
    emit overlay-state $orc $W/state.txt
    "$ST" -u -f $U -C $W/src claw-code/docs claw-code/tests; emit tar-update-u $? $U
    "$ST" -t -f $U > $W/list.txt; emit listing-after-u $? $W/list.txt
    "$ST" --delete -f $U claw-code/docs/XC_NEW.md claw-code/tests/test_security_scope.py; emit tar-delete $? $U
    "$ST" -t -f $U > $W/list.txt; emit listing-after-delete $? $W/list.txt

    # 3. Encryption. The salt and nonce are random, so two runs on one machine already
    #    differ and the ciphertext cannot be compared; what must agree is what comes back
    #    out. decrypt-own and decrypt-foreign should both equal sub-plain.
    # 3. 加密。salt 與 nonce 是隨機的，同一台機器跑兩次就已經不同，密文無從比較；必須一致
    #    的是解出來的內容。decrypt-own 與 decrypt-foreign 都應等於 sub-plain。
    "$ST" -c -f $W/p.bin -C $W/src claw-code/tests; emit sub-plain $? $W/p.bin
    "$ST" -c --zstd -f $W/p.bin -C $W/src claw-code/tests; emit sub-zstd $? $W/p.bin
    "$ST" -c --encrypt --keyfile $AUX/key.bin -f $W/e1.bin -C $W/src claw-code/tests; emit encrypt-run1 $? $W/e1.bin
    "$ST" -c --encrypt --keyfile $AUX/key.bin -f $W/e2.bin -C $W/src claw-code/tests; emit encrypt-run2 $? $W/e2.bin
    "$ST" --decrypt-only -f $W/e1.bin --keyfile $AUX/key.bin > $W/p.bin; emit decrypt-own $? $W/p.bin
    "$ST" -c --encrypt --zstd --keyfile $AUX/key.bin -f $W/ez.bin -C $W/src claw-code/tests
    "$ST" --decrypt-only -f $W/ez.bin --keyfile $AUX/key.bin > $W/p.bin; emit decrypt-own-zstd $? $W/p.bin
    if [[ -f $AUX/foreign.enc ]]; then
        "$ST" --decrypt-only -f $AUX/foreign.enc --keyfile $AUX/key.bin > $W/p.bin; emit decrypt-foreign $? $W/p.bin
        mkdir -p $W/fx && "$ST" -x -f $AUX/foreign.enc --keyfile $AUX/key.bin -C $W/fx; xrc=$?
        if (( xrc == 0 )) && diff -r $W/src/claw-code/tests $W/fx/claw-code/tests > /dev/null; then
            print -r -- "XC-NOTE extract-foreign: tree identical / 解出的目錄與來源相同"
        else
            print -r -- "XC-NOTE extract-foreign: FAILED rc=$xrc / 失敗"
        fi
    fi
    print -r -- "XC-DONE"
    ;;

record)
    (( $# == 3 || $# == 4 )) || usage
    plat=$1; ver=$2; lines=$3; out=${4:-$DEFAULT_CSV2}
    grep -a -q '^XC-DONE' "$lines" || { print -u2 -- "no XC-DONE in $lines: the run did not finish / run 沒有跑完"; exit 1 }
    if [[ ! -f $out ]]; then
        print -r -- "platform,swift_tar_version,case,rc,bytes,sha256" > "$out"
        print -r -- "平台,版本戳,項目,退出碼,位元組,sha256" >> "$out"
    fi
    # Drop this platform's earlier records, last first so the numbering stays valid.
    # 先移除這個平台的舊紀錄，由後往前刪，編號才不會跑掉。
    n=$(csv2 -r -i "$out" | wc -l | tr -d ' ')
    for (( r = n; r >= 1; r-- )); do
        [[ $(csv2 -get $r:1 -i "$out") == $plat ]] && { csv2 -delete $r -i "$out" --in-place || exit 1 }
    done
    count=0
    grep -a '^XC ' "$lines" | tr -d '\r' | while read -r tag name rc bytes hash; do
        csv2 -append "$plat,$ver,$name,$rc,$bytes,$hash" -i "$out" --in-place || exit 1
        (( count++ ))
    done
    print -r -- "recorded $count cases for $plat in $out / 已記錄 $plat 的 $count 項"
    grep -a '^XC-NOTE' "$lines" | tr -d '\r'
    ;;

compare)
    (( $# == 2 || $# == 3 )) || usage
    a=$1; b=$2; in=${3:-$DEFAULT_CSV2}
    typeset -A ha hb ra rb; typeset -a order
    n=$(csv2 -r -i "$in" | wc -l | tr -d ' ')
    for (( r = 1; r <= n; r++ )); do
        p=$(csv2 -get $r:1 -i "$in"); name=$(csv2 -get $r:3 -i "$in")
        if [[ $p == $a ]]; then ha[$name]=$(csv2 -get $r:6 -i "$in"); ra[$name]=$(csv2 -get $r:4 -i "$in"); order+=($name)
        elif [[ $p == $b ]]; then hb[$name]=$(csv2 -get $r:6 -i "$in"); rb[$name]=$(csv2 -get $r:4 -i "$in"); fi
    done
    (( ${#ha} && ${#hb} )) || { print -u2 -- "no records for $a or $b in $in / 找不到紀錄"; exit 1 }
    # Ciphertext is expected to differ; everything else is expected to match.
    # 密文預期不同；其餘預期相同。
    random=(encrypt-run1 encrypt-run2)
    bad=0
    for name in $order; do
        if (( ! ${+hb[$name]} )); then print -r -- "only-$a      $name"; continue; fi
        if [[ ${ra[$name]} != 0 || ${rb[$name]} != 0 ]]; then
            print -r -- "NOT-COMPARED  $name (rc $a=${ra[$name]} $b=${rb[$name]})"; bad=1; continue
        fi
        if (( ${random[(Ie)$name]} )); then
            if [[ ${ha[$name]} != ${hb[$name]} ]]; then print -r -- "differs-ok    $name (random salt and nonce / 隨機 salt 與 nonce)"
            else print -r -- "SAME-BUT-RANDOM $name"; bad=1; fi
        elif [[ ${ha[$name]} == ${hb[$name]} ]]; then print -r -- "same          $name"
        else print -r -- "DIFFERENT     $name"; bad=1; fi
    done
    for name in ${(k)hb}; do (( ${+ha[$name]} )) || print -r -- "only-$b      $name"; done
    # Within one platform: what decryption gives back must be what was encrypted.
    # 同一平台內：解密得到的必須就是當初加密的內容。
    for p in $a $b; do
        if [[ $p == $a ]]; then typeset -A h=("${(@kv)ha}"); else typeset -A h=("${(@kv)hb}"); fi
        for pair in decrypt-own:sub-plain decrypt-own-zstd:sub-zstd decrypt-foreign:sub-plain; do
            x=${pair%%:*}; y=${pair#*:}
            (( ${+h[$x]} )) || continue
            if [[ ${h[$x]} == ${h[$y]} ]]; then print -r -- "same          $p: $x = $y"
            else print -r -- "DIFFERENT     $p: $x vs $y"; bad=1; fi
        done
    done
    exit $bad
    ;;

*) usage ;;
esac
