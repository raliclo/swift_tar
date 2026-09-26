#!/bin/zsh
# =====================================================================
# chunk_size_tradeoff.zsh -- TAR_CHUNK_SIZE 取 4／8／16 MiB 時，速度與大小各付出什麼。
# chunk_size_tradeoff.zsh -- what speed and size trade for TAR_CHUNK_SIZE at 4/8/16 MiB.
#
# `TAR_CHUNK_SIZE`（swift_tar.swift，`1 << 22` = 4 MiB）是編譯期常數。`ParallelChunkSink`
# 的建構子雖然收 `chunkSize:`，但兩個呼叫端都不傳值、編譯腳本也不覆寫，所以沒有任何旗標能
# 調它。本腳本因此**重建**：把原始碼複製到暫存目錄，只替換那一行常數（逐支確認替換成功），
# 以與 compile_tar.zsh 相同的 swiftc 參數與既有的 build/ 產物建出每一支變體。
# **不動工作樹、不呼叫 generate_version.zsh（它會寫 version-mac.txt）、不覆蓋已安裝的
# swift_tar。**
#
# 注意：`zstd_decode_gap.zsh --mode chunk` 不是這個問題。那個模式固定 chunk 大小、改
# `--zstd-level`，量的是「frame 數固定而壓縮量改變」；兩者不可互相引用。
#
# `TAR_CHUNK_SIZE` is a compile-time constant with no flag reaching it, so this rebuilds: the
# source is copied to a temp directory, only that constant is replaced (each replacement is
# checked), and each variant is built with compile_tar.zsh's swiftc arguments against the
# existing build/ artefacts. The work tree, version-mac.txt and the installed binary are left
# alone. `zstd_decode_gap.zsh --mode chunk` answers a different question.
#
# 對照組 / Controls:
#   - 與現值相同的那一支（預設 4 MiB）用與其他變體**完全相同的方式**建置——三者之間唯一的
#     差異就是那個常數。
#   - 已安裝的 swift_tar（--control）檢查「本腳本的建置方式等同正式建置」：它應與同值的變體
#     吻合。不吻合就代表建置方式本身有差，其餘結論不可信。
#   The variant equal to the shipped value is built exactly like the others, so the constant is
#   the only difference; the installed binary checks that this build method matches production.
#
# 量法 / Method: 指令與 benchmark 相同（`czf`、`-c --zstd --zstd-level 9`、`-cf`），解壓以
# `--cat` 量（不寫檔，只量解壓本身），輸出在 RAM disk，**逐輪交錯、取最小值**。
# Same commands as the benchmark; decode via --cat (no file writes); output on a RAM disk;
# interleaved rounds, minimum taken.
#
# ---------------------------------------------------------------------
# 結果（2026-09-27 05:39，swift_tar f6ba52c，claw-code，5 輪）：**維持 4 MiB。**
# RESULT (2026-09-27 05:39, swift_tar f6ba52c, claw-code, 5 rounds): KEEP 4 MiB.
#
#   chunk    ZSTD 大小     ZSTD 解壓        TGZ
#   4 MiB    382.6M        1157 MB/s        速度和大小都跟 chunk 無關
#   8 MiB    −2.6%         −3.6%
#   16 MiB   −4.0%         −5.1%
#
# 完整數字見同目錄 chunk_size_tradeoff.txt。
#
# **大小的差異是確定的，速度的差異不是。** 壓縮後大小與量測時的負載無關，兩次執行在輸出
# 的精度（0.1 MiB）內相同（8 MiB −2.6%、16 MiB −4.0%；TGZ 0）。速度則在這次執行的雜訊範圍內：對照組（已安裝的
# 正式版，與 4 MiB 同值）自己就偏離 4 MiB 最多 5.8%，執行期間另一個工作的編譯把 load 推到
# 18。同一天較早一次未存檔的執行量到 16 MiB 解壓 −10%，這次是 −5.1%——**沒有重現**，故不
# 採用。兩次唯一一致的是方向：chunk 越大，ZSTD 解壓與無壓縮 tar 越慢。
#
# 對照組 5.8% 的偏差超過了下方「吻合在數個百分點內」的判讀門檻，依該規則**本輪的速度結論
# 保留不用**。它比較像負載而非建置方式不同：對照組產出的 TGZ 與 ZSTD 封存大小與 4 MiB 那支
# 在輸出精度（0.1 MiB）內相同（468.6M／382.6M），輸出一致而只有速度偏離。這只是旁證——大小
# 相同到 0.1 MiB 不等於位元組相同，本腳本沒有比對封存內容。大小的結論不受影響；速度要在安靜
# 的機器上重跑本腳本才能下結論。
# The control's 5.8% deviation exceeds the "within a few percent" rule below, so this run's
# speed findings are withheld. Load is the likelier cause than the build: the control's archives
# match the 4 MiB variant's sizes to the printed 0.1 MiB, so only the timing drifted. That is
# circumstantial -- equal to 0.1 MiB is not byte-identical, and archive contents are not compared.
# Size findings stand; speed needs a rerun on a quiet machine.
#
# 因此維持 4 MiB 的理由是：放大 chunk 只換到 ≤4% 的 ZSTD 大小，速度沒有變好、兩次量到的
# 方向都是變慢；TGZ 則完全不受影響（gzip 視窗只有 32 KB，chunk 碰不到它）。
#
# Size differences are deterministic and repeat across runs to the printed 0.1 MiB (−2.6% at 8 MiB, −4.0% at
# 16 MiB; TGZ unchanged). Speed differences are not: the control, identical to 4 MiB, itself
# deviated by up to 5.8% in this run, and an earlier unsaved run's −10% decode at 16 MiB came
# out at −5.1% here -- not reproduced, so not used. The only consistent speed signal is the
# direction. Keep 4 MiB: a larger chunk buys at most 4% of ZSTD size and no speed.
# ---------------------------------------------------------------------
#
# 用法 / Usage:
#   verifications/chunk_size_tradeoff.zsh [--reps N] [--sizes "4 8 16"] [--source REV]
#                                         [--corpus DIR] [--control BIN] [--out FILE]
#
#   --reps N        每支變體量幾輪（預設 5），取最小值 / rounds per variant, minimum taken
#   --sizes LIST    要建的 chunk 大小，單位 MiB（預設 "4 8 16"）
#   --source REV    從這個 git 版本取 swift_tar.swift／rgb1.swift／crypto.swift 建置。預設為
#                   工作樹——但工作樹若有未提交改動，變體會混進那些改動，輸出會標記 dirty。
#                   Build from this git revision; default is the work tree, marked dirty if so.
#   --corpus DIR    量測用的資料夾（預設為上層 lzfse2 的 claw-code）
#   --control BIN   對照用的已安裝執行檔（預設 /opt/homebrew/bin/swift_tar；"none" 略過）
#   --out FILE      另存一份輸出（預設 verifications/chunk_size_tradeoff.txt；"-" 不存）
#   -h, --help      顯示本說明
#
# 前置 / Prerequisite: build/ 底下需有 compile_tar.zsh 建出的 libarchive、liblzma、liblz4、
# libzstd 與 libarchive_zip_bridge.o。本腳本不代為建置——那些建置腳本會動工作樹。
# =====================================================================
set -uo pipefail
zmodload zsh/datetime   # $EPOCHREALTIME；沒載入時是空值，所有計時會靜默變成 0

HERE=${0:A:h}
ROOT=${HERE:h}
REPS=5
SIZES=(4 8 16)
SOURCE=""
CORPUS=${ROOT:h}/claw-code
CONTROL=/opt/homebrew/bin/swift_tar
OUT=$HERE/chunk_size_tradeoff.txt

while (( $# )); do
    case $1 in
        --reps)    shift; REPS=${1:?--reps needs a number} ;;
        --sizes)   shift; SIZES=(${=${1:?--sizes needs a list}}) ;;
        --source)  shift; SOURCE=${1:?--source needs a revision} ;;
        --corpus)  shift; CORPUS=${1:?--corpus needs a directory} ;;
        --control) shift; CONTROL=${1:?--control needs a path or none} ;;
        --out)     shift; OUT=${1:?--out needs a file or -} ;;
        -h|--help)
            # 以第二條 `# =====` 標記算出說明的結尾，不寫死行號：寫死的範圍會在標頭變長時
            # 「成功地」印出被截斷的說明（page_fault_attribution.zsh 踩過）。
            local_end=$(grep -n '^# =====' "${0:A}" | sed -n '2p' | cut -d: -f1)
            sed -n "2,${local_end}p" "${0:A}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) print -ru2 -- "unknown option: $1"; exit 2 ;;
    esac
    shift
done

die() { print -ru2 -- "錯誤 / error: $*"; exit 1 }
[[ -d $CORPUS ]] || die "找不到語料 $CORPUS；以 --corpus 指定 / corpus not found"
for a in build/libarchive_zip_bridge.o build/libarchive-macos/libarchive/libarchive.a \
         build/xz-macos/liblzma.a build/lz4-macos/liblz4.a build/zstd-macos/lib/libzstd.a; do
    [[ -f $ROOT/$a ]] || die "缺少 $a；先以 compile_tar.zsh 建置一次 / build first"
done
[[ -f $ROOT/lzfse2/lzfse-cli.swift ]] || die "缺少 lzfse2/lzfse-cli.swift（submodule 未取得）"

run() {
    W=$(mktemp -d -t chunk_size_tradeoff)
    DEV=""
    trap '[[ -n $DEV ]] && hdiutil detach $DEV -force >/dev/null 2>&1; rm -rf $W' EXIT INT TERM

    # ---- 原始碼 / sources ---------------------------------------------------
    local src_desc dirty=no
    if [[ -n $SOURCE ]]; then
        for f in swift_tar.swift rgb1.swift crypto.swift; do
            git -C $ROOT show "$SOURCE:$f" > $W/$f 2>/dev/null || die "git show $SOURCE:$f 失敗"
        done
        src_desc="$(git -C $ROOT rev-parse --short "$SOURCE")"
    else
        cp $ROOT/swift_tar.swift $ROOT/rgb1.swift $ROOT/crypto.swift $W/
        src_desc="work tree @ $(git -C $ROOT rev-parse --short HEAD)"
        [[ -n $(git -C $ROOT status --porcelain -- swift_tar.swift rgb1.swift crypto.swift) ]] && dirty=yes
    fi
    grep -v "^runCLI()$" $ROOT/lzfse2/lzfse-cli.swift > $W/cli.swift

    local shipped=$(grep -E '^let TAR_CHUNK_SIZE = ' $W/swift_tar.swift)
    [[ $shipped == 'let TAR_CHUNK_SIZE = 1 << 22' ]] \
        || die "原始碼中的常數不是預期的 '1 << 22'，而是：${shipped:-（找不到）}——替換規則需要更新"

    print -- "=============================================================="
    print -- " TAR_CHUNK_SIZE 取捨 / chunk size trade-off"
    print -- "=============================================================="
    print -- "  日期 / date     : $(date '+%Y-%m-%d %H:%M:%S')"
    print -- "  機器 / machine  : $(sysctl -n hw.model)  $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    print -- "  原始碼 / source : $src_desc   未提交改動 / dirty: $dirty"
    print -- "  語料 / corpus   : $CORPUS  ($(du -sm $CORPUS | cut -f1) MiB)"
    print -- "  輪數 / reps     : $REPS（逐輪交錯、取最小值）"
    print -- "  負載 / load     : $(uptime | sed 's/.*averages: //')（開始）"
    [[ $dirty == yes ]] && print -- "  注意：工作樹的原始碼有未提交改動，變體含那些改動 / variants include uncommitted changes"
    print -- ""

    # ---- 建置 / build -------------------------------------------------------
    typeset -gA BIN
    local S got rc
    for S in $SIZES; do
        mkdir -p $W/v$S
        sed "s/^let TAR_CHUNK_SIZE = 1 << 22\$/let TAR_CHUNK_SIZE = $S << 20/" $W/swift_tar.swift > $W/v$S/swift_tar.swift
        # sed 替換失敗時不報錯、原樣輸出——所以要數，不是相信。
        # sed leaves the text unchanged without error when nothing matches, so count.
        got=$(grep -c "^let TAR_CHUNK_SIZE = $S << 20\$" $W/v$S/swift_tar.swift)
        (( got == 1 )) || die "$S MiB：常數替換失敗（命中 $got 行）"
        print "let swiftTarBuildVersion = \"chunk-${S}MiB\"" > $W/v$S/ver.swift
        ( cd $ROOT && swiftc -O -swift-version 6 $W/cli.swift $W/v$S/ver.swift $W/v$S/swift_tar.swift \
              $W/rgb1.swift $W/crypto.swift \
              build/libarchive_zip_bridge.o build/libarchive-macos/libarchive/libarchive.a \
              build/xz-macos/liblzma.a build/lz4-macos/liblz4.a build/zstd-macos/lib/libzstd.a \
              -o $W/swift_tar_$S -lz -lbz2 ) > $W/build_$S.log 2>&1
        rc=$?
        (( rc == 0 )) || { tail -5 $W/build_$S.log >&2; die "$S MiB 建置失敗 rc=$rc"; }
        print -- "  建置 / built  ${S} MiB   $($W/swift_tar_$S --version 2>&1 | head -1)   診斷 $(grep -cE ': (warning|error):' $W/build_$S.log) 行"
        BIN[$S]=$W/swift_tar_$S
    done
    local -a VARIANTS=($SIZES)
    if [[ $CONTROL != none && -x $CONTROL ]]; then
        BIN[control]=$CONTROL; VARIANTS+=(control)
        print -- "  對照 / control  $CONTROL   $($CONTROL --version 2>&1 | head -1)"
    fi
    print -- ""

    # ---- RAM disk -----------------------------------------------------------
    # 只取 /dev/diskN：hdiutil 會多印一行棄用警告。 / Take only /dev/diskN.
    DEV=$(hdiutil attach -nomount ram://$(( 2048 * 2048 )) 2>/dev/null | grep -o '/dev/disk[0-9]*' | head -1)
    [[ -n $DEV ]] || die "RAM disk 建立失敗"
    local RD=/Volumes/chunk_tradeoff
    diskutil eraseVolume HFS+ chunk_tradeoff $DEV >/dev/null 2>&1
    [[ -d $RD ]] || die "RAM disk 掛載失敗"

    # ---- 量測 / measure -----------------------------------------------------
    typeset -gA BEST SIZE
    local parent=${CORPUS:h} leaf=${CORPUS:t}
    tm() {  # key cmd... — 量到 0 或失敗就中止，不讓它變成表格裡的一格
        local k=$1; shift
        local t0=$EPOCHREALTIME
        "$@" >/dev/null 2>$RD/err
        local rc=$? dt=$(( EPOCHREALTIME - t0 ))
        (( rc == 0 && dt > 0.05 )) || { cat $RD/err >&2; die "量測失敗 $k rc=$rc dt=$dt"; }
        (( ${BEST[$k]:-999999} > dt )) && BEST[$k]=$dt
    }
    local rep v b
    for rep in {1..$REPS}; do
        for v in $VARIANTS; do
            b=${BIN[$v]}
            tm tgz_enc/$v $b czf $RD/a.tgz -C $parent $leaf;                      SIZE[tgz/$v]=$(stat -f %z $RD/a.tgz)
            tm tgz_dec/$v $b --cat -f $RD/a.tgz;                                  rm -f $RD/a.tgz
            tm zst_enc/$v $b -c --zstd --zstd-level 9 -f $RD/a.zst -C $parent $leaf; SIZE[zst/$v]=$(stat -f %z $RD/a.zst)
            tm zst_dec/$v $b --cat -f $RD/a.zst;                                  rm -f $RD/a.zst
            tm tar_enc/$v $b -cf $RD/a.tar -C $parent $leaf;                      rm -f $RD/a.tar
        done
        print -- "  第 $rep／$REPS 輪完成 / round done"
    done

    # ---- 結果 / results -----------------------------------------------------
    local raw=$(du -sm $CORPUS | cut -f1) base=${SIZES[1]} k
    print -- ""
    print -- "--- MB/s（= $raw MiB ÷ 最小秒數）/ MB/s from minimum seconds ---"
    printf '  %-9s %9s %9s %9s %9s %9s %11s %11s\n' chunk tgz_enc tgz_dec zst_enc zst_dec tar_enc tgz_MiB zst_MiB
    for v in $VARIANTS; do
        printf '  %-9s' "$v$([[ $v != control ]] && print ' MiB')"
        for k in tgz_enc tgz_dec zst_enc zst_dec tar_enc; do printf ' %9.0f' $(( raw / BEST[$k/$v] )); done
        printf ' %11.1f %11.1f\n' $(( SIZE[tgz/$v] / 1048576.0 )) $(( SIZE[zst/$v] / 1048576.0 ))
    done
    print -- ""
    print -- "--- 相對 ${base} MiB / relative to ${base} MiB（速度為 MB/s 的變化，大小為檔案大小的變化）---"
    printf '  %-9s %9s %9s %9s %9s %9s %11s %11s\n' chunk tgz_enc tgz_dec zst_enc zst_dec tar_enc tgz_size zst_size
    for v in $VARIANTS; do
        printf '  %-9s' "$v$([[ $v != control ]] && print ' MiB')"
        for k in tgz_enc tgz_dec zst_enc zst_dec tar_enc; do
            printf ' %+8.1f%%' $(( (BEST[$k/$base] / BEST[$k/$v] - 1) * 100 ))
        done
        printf ' %+10.1f%% %+10.1f%%\n' $(( (SIZE[tgz/$v] * 1.0 / SIZE[tgz/$base] - 1) * 100 )) $(( (SIZE[zst/$v] * 1.0 / SIZE[zst/$base] - 1) * 100 ))
    done
    print -- ""
    print -- "--- 最小秒數 / minimum seconds ---"
    for v in $VARIANTS; do
        print -n "  $v:"; for k in tgz_enc tgz_dec zst_enc zst_dec tar_enc; do printf ' %s=%.3f' $k ${BEST[$k/$v]}; done; print
    done
    print -- ""
    print -- "  負載 / load     : $(uptime | sed 's/.*averages: //')（結束）"
    print -- "  判讀：對照組應與 ${base} MiB 每項吻合在數個百分點內；不吻合代表建置方式本身有差。"
    print -- "  Reading: the control must match ${base} MiB within a few percent, or the build differs."
    print -- "  4% 以內的差距不作為結論。 / Differences under 4% are not findings."
}

# 輸出另存一份。用 pipestatus 取 run 的狀態，不取 tee 的——`$?` 在管線之後指的是最後一個。
# Keep a copy of the output; take run's status from pipestatus, not tee's.
if [[ $OUT == - ]]; then
    run
    exit $?
fi
run | tee "$OUT"
st=(${pipestatus})
(( st[1] == 0 )) || { print -ru2 -- "執行失敗，$OUT 為不完整的輸出 / run failed; $OUT is partial"; exit ${st[1]}; }
