#!/bin/zsh
# =====================================================================
# faults_by_path.zsh -- 把 page fault 歸因到 FileWriterPool 的逐檔緩衝，或排除它。
# faults_by_path.zsh -- attribute the page faults to FileWriterPool's per-file
#                       buffering, or rule it out.
#
# R50-Mac 待辦第 2 項：native 解壓比 external 慢，三個競爭假設已排除（E-Cluster 參與度、
# `-n` 設定、平行度），唯一剩下的線索是 page fault 差 64 倍（128,042 對 1,990），指向
# `FileWriterPool` 的逐檔緩衝。待辦寫的是「先量出 sys 時間的去向，再提出任何機制」。
#
# **本腳本不重建任何東西。** 它打在 swift_tar.swift:4019 那個既有的分支上：
#
#     if let pool = pool, size <= UInt64(FileWriterPool.smallFileMax) {
#         var data = Data()                     // ← 每個小檔整份緩衝
#
# smallFileMax 是 4 MiB。**≤4 MiB 的成員整份緩衝進一個 Data()，>4 MiB 的完全跳過這條路**
# 而 inline 串流。於是只要讓檔案大小跨過那條線，就能在同一個執行檔上開關這條程式碼路徑，
# 不必改 smallFileMax 重建。
#
# 三個語料，**總位元組數相同**，只有成員大小與數量不同：
#
#   A   32 × 3 MiB = 96 MiB   ≤4 MiB → 走緩衝   count 32
#   B   16 × 6 MiB = 96 MiB   >4 MiB → 不走緩衝 count 16
#   C   96 × 1 MiB = 96 MiB   ≤4 MiB → 走緩衝   count 96
#
#   A vs C：位元組數相同、路徑相同、成員數 3 倍 → 隔離「數量」的效應
#   A vs B：位元組數相同、路徑不同           → 隔離「緩衝路徑本身」的效應
#
# **可證偽**：若逐檔緩衝是成因，B 的 fault 應遠低於 A 與 C，且 C 應高於 A。若 B 與 A
# 相當，這個候選就該被排除，而我們回到零個候選——那也是有價值的結果，本輪的結論已經被
# 推翻過兩次，都是數字不足就提機制。
#
# 資料用 /dev/urandom：不可壓縮，於是解壓縮的 CPU 不再是干擾項，量到的是寫出路徑本身
# ——那正是受測的東西。
#
# Three corpora of identical total bytes differing only in member size, straddling the 4 MiB
# threshold that switches FileWriterPool's whole-file buffering on and off in the existing
# binary. No rebuild. Falsifiable: if buffering is the cause, B is far below A and C, and C
# is above A; if B matches A the candidate is excluded and we are back to none.
#
# ---------------------------------------------------------------------
# 結果（2026-09-04，7 輪，輪間變異 < 1%）：**候選被排除。**
# RESULT (2026-09-04, 7 reps, run-to-run variation under 1%): CANDIDATE EXCLUDED.
#
#   語料  成員      路徑      fault      每 MiB   每檔      每 4KiB 分頁
#   C     96 × 1M   緩衝       8,144       84       85        0.33
#   A     32 × 3M   緩衝      26,424      275      826        1.08
#   D     24 × 4M   緩衝      26,206      272    1,092        1.07
#   E     24 × 5M   inline    28,086      234    1,170        0.91
#   B     16 × 6M   inline    20,482      213    1,280        0.83
#
# **決定性的是 D 與 E**：成員數相同（24）、大小相鄰（4 對 5 MiB）、而分支翻面。每頁
# fault 由 1.07 平順走到 0.91，**分界處沒有不連續**。若逐檔緩衝是成因，D 應遠高於 E。
#
# 更強的反證是 C：它把緩衝路徑用得最重（96 個成員全部走它），fault 卻是全部之中最少的
# ——每 MiB 84，是 A 的三分之一。
#
# 每頁 fault 隨**單次配置的大小**連續變化且跨越分支時不跳動：1 MiB 為 0.33，3–4 MiB 達到
# 約 1.07（幾乎每個分頁一次），再緩降至 6 MiB 的 0.83。那個形狀指向配置器而非寫入池——
# macOS 的 malloc 對超過門檻的配置以 mmap 取得、釋放時歸還，於是下一次配置在首次觸碰時
# 逐頁 zero-fill。inline 路徑同樣逐塊配置，因此同樣付這個代價。
#
# **R50-Mac 待辦第 2 項的唯一候選就此排除，回到零個候選。** 這是該節第三次推翻自己：前兩次
# 是「解壓與寫檔沒有重疊」與「external 靠管線平行取勝」，這一次是 smallFileMax。
#
# **界限，寫清楚以免被誤引**：本實驗量的是 swift_tar 在合成語料上的解壓，**不是** native
# 對 external 那個 64 倍差距本身；它只回答「逐檔緩衝是不是 fault 的來源」，答案是否。
# 資料為 /dev/urandom（不可壓縮），真實語料會壓縮，解壓端的配置行為因此不同。
#
# D versus E is decisive: same member count, adjacent sizes, branch flipped, and faults per
# page move smoothly from 1.07 to 0.91 with no discontinuity. C is the stronger refutation --
# it uses the buffered path most heavily of all and has the fewest faults per MiB by a factor
# of three. Faults track allocation size continuously across the branch, which points at the
# allocator rather than the pool. The sole remaining candidate is therefore excluded and the
# count returns to zero. Limits, stated so this is not miscited: it measures swift_tar decode
# on synthetic incompressible corpora, not the 64x native-versus-external gap itself.
# ---------------------------------------------------------------------
#
# 用法 / Usage:
#   faults_by_path.zsh [--reps N] [--keep]
# =====================================================================
set -uo pipefail

REPS=7
KEEP=0
while (( $# )); do
    case "$1" in
        --reps) shift; REPS="${1:?--reps needs a number}" ;;
        --keep) KEEP=1 ;;
        -h|--help) sed -n '2,45p' "${0:A}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print -ru2 -- "unknown option: $1"; exit 2 ;;
    esac
    shift
done

BIN=${SWIFT_TAR_BIN:-/Users/raliclo/proj/lzfse2/swift_tar/release/swift_tar}
[[ -x $BIN ]] || { print -ru2 -- "no swift_tar at $BIN"; exit 1 }

print -- "=============================================================="
print -- " page fault 歸因：FileWriterPool 的逐檔緩衝 / attributing page faults"
print -- "=============================================================="
print -- "  執行檔 / binary : $BIN"
print -- "  sha256          : $(shasum -a 256 "$BIN" | cut -d' ' -f1)"
print -- "  重複次數 / reps : $REPS   （取最小值 / minimum taken）"
print -- "  smallFileMax    : 4 MiB   （swift_tar.swift:2501）"
print -- ""

# RAM disk。實際磁碟上反覆寫入會讓後續量測單調劣化，最小值於是挑到序列早期那次而非真正
# 的最佳值——mistakes.md 第 2 條記過這件事，`-n 1` 就是這樣「贏」了兩輪。
# A RAM disk: repeated writes to the internal SSD degrade later measurements monotonically,
# so the minimum picks an early run rather than the best one.
SECTORS=$(( 1536 * 1024 * 1024 / 512 ))
# 只取 /dev/diskN，不要整行：hdiutil 現在會印一行棄用警告，而 `tr -d ' '` 會把警告與
# 裝置名黏成一個字串，`diskutil` 於是收到一個不存在的裝置並回報 "Unable to find disk"
# ——訊息指向裝置，成因卻在解析。
# Take only /dev/diskN: hdiutil now prints a deprecation warning that would otherwise be
# glued onto the device name, and diskutil then reports a missing disk rather than a parse
# problem.
DEV=$(hdiutil attach -nomount ram://$SECTORS 2>/dev/null | grep -o '/dev/disk[0-9]*' | head -1)
[[ -n $DEV ]] || { print -ru2 -- "could not create the RAM disk"; exit 1 }
# diskutil eraseVolume 會格式化並掛載，且不需要 sudo；newfs_hfs + mount -t hfs 需要 root。
# eraseVolume formats and mounts without sudo, which newfs_hfs + mount -t hfs would need.
MNT=/Volumes/faultprobe
diskutil eraseVolume HFS+ faultprobe "$DEV" >/dev/null 2>&1
[[ -d $MNT ]] || { hdiutil detach "$DEV" >/dev/null 2>&1; print -ru2 -- "could not format/mount $DEV"; exit 1 }

cleanup() {
    cd /
    if (( ! KEEP )); then
        diskutil unmount force "$MNT" >/dev/null 2>&1
        hdiutil detach "$DEV" >/dev/null 2>&1
    else
        print -- "  （--keep：RAM disk 保留在 $MNT / left mounted）"
    fi
}
trap cleanup EXIT INT TERM

print -- "  RAM disk        : $DEV → $MNT  (1536 MiB)"
print -- ""

# ---- 語料 / corpora --------------------------------------------------
# name:count:size_mib
# D 與 E 是緊貼 4 MiB 分界的一對：**成員數相同、大小只差 1 MiB，而分支翻面**。
# A/B/C 之間同時變動了大小與數量，分不出是哪一個在起作用；D/E 只讓分支變。
# D and E straddle the 4 MiB threshold with the same member count and adjacent sizes, so only
# the branch changes. A/B/C vary size and count together and cannot separate the two.
CORPORA=(A:32:3 B:16:6 C:96:1 D:24:4 E:24:5)

print -- "--- 建立語料與封存 / building corpora and archives ---"
for spec in $CORPORA; do
    name=${spec%%:*}; rest=${spec#*:}; cnt=${rest%%:*}; mib=${rest##*:}
    d="$MNT/src_$name"
    mkdir -p "$d"
    for i in {1..$cnt}; do
        dd if=/dev/urandom of="$d/f$i.bin" bs=1m count=$mib 2>/dev/null
    done
    "$BIN" -c --zstd -f "$MNT/$name.tar.zst" -C "$MNT" "src_$name" 2>/dev/null
    # 封存完就刪掉來源：RAM disk 只有 1536 MiB，五個語料的來源加起來超過三分之一。
    # Drop the source once archived; the RAM disk is 1536 MiB and five sources would take a
    # third of it for no further use.
    rm -rf "$d"
    total=$(( cnt * mib ))
    # **不要叫它 `path`。** zsh 把小寫 `path` 與 `PATH` 綁在一起（`cdpath`/`fpath`/
    # `manpath` 同理），`path=1` 會把 PATH 整個換成 "1"，其後每一個外部指令都
    # `command not found`——而迴圈本身照跑、退出碼 0、表格照印，只是每一格都是 0。
    # Never name a variable `path` in zsh: it is tied to PATH, so `path=1` replaces PATH and
    # every external command afterwards is not found, while the loop still exits zero.
    buffered=$(( mib <= 4 ? 1 : 0 ))
    printf '  %s  %3d 檔 × %d MiB = %3d MiB   %s   封存 %s\n' \
        "$name" "$cnt" "$mib" "$total" \
        "$( (( buffered )) && print -- '走緩衝 buffered  ' || print -- '不走緩衝 inline  ')" \
        "$(du -m "$MNT/$name.tar.zst" | cut -f1) MiB"
done
print -- ""

# ---- 量測 / measure --------------------------------------------------
# 兩個串流各自導向檔案，不用 `2>&1 >…`：在 zsh 的 MULTIOS 之下，那個形狀在管線中會讓
# stdout 同時流向兩處（mistakes.md 第 3 條）。
# Both streams to files rather than `2>&1 >…`, which leaks under zsh's MULTIOS in a pipeline.
ERR="$MNT/.time.err"

decode_once() {   # <name> -> "faults real user sys"
    local n=$1 out="$MNT/out_$1"
    rm -rf "$out"; mkdir -p "$out"
    /usr/bin/time -l "$BIN" -x -f "$MNT/$n.tar.zst" -C "$out" >/dev/null 2>"$ERR"
    local faults real user sys
    faults=$(grep -E 'page reclaims' "$ERR" | awk '{print $1}')
    read real user sys <<< "$(grep -E '[0-9.]+ +real' "$ERR" | head -1 | awk '{print $1, $3, $5}')"
    rm -rf "$out"
    # 量不到就**大聲失敗**，不要讓它靜默變成 0。第一版沒有這道防護，而一個把 PATH 弄壞的
    # 變數名（`path`）讓每個外部指令都消失，於是三個語料全部量到 0 —— 表格照印、退出碼 0、
    # 每一欄都是 0，讀起來像「這台機器沒有 page fault」而不是「量測壞了」。
    # Fail loudly rather than letting a failed measurement become a silent 0: the first
    # version printed a full table of zeros after a variable name broke PATH.
    if [[ -z ${faults:-} || ${faults:-0} -eq 0 || -z ${real:-} ]]; then
        print -ru2 -- "量測失敗 / measurement failed for '$n' — time -l 的輸出如下 / raw output:"
        sed 's/^/    /' "$ERR" >&2
        exit 1
    fi
    print -- "$faults $real $user $sys"
}

typeset -A MINF MINR MINU MINS
for spec in $CORPORA; do
    name=${spec%%:*}; MINF[$name]=999999999; MINR[$name]=999999; MINU[$name]=999999; MINS[$name]=999999
done

print -- "--- 交錯量測 / interleaved, $REPS 輪 ---"
print -- "    每一輪都跑過 A B C，不是跑完一組再跑另一組。"
for r in {1..$REPS}; do
    line="  rep $r:"
    for spec in $CORPORA; do
        name=${spec%%:*}
        read f re u s <<< "$(decode_once $name)"
        (( f < MINF[$name] )) && MINF[$name]=$f
        (( ${re%%s*} < MINR[$name] )) && MINR[$name]=${re%%s*}
        (( u < MINU[$name] )) && MINU[$name]=$u
        (( s < MINS[$name] )) && MINS[$name]=$s
        line="$line  $name=$f"
    done
    print -- "$line"
done
print -- ""

# ---- 結果 / results --------------------------------------------------
print -- "--- 最小值 / minima ---"
printf '  %-3s %-8s %-6s %-12s %-12s %-9s %-9s %s\n' \
    語料 路徑 成員數 "page reclaims" "每 MiB" "real" "user" "sys"
for spec in $CORPORA; do
    name=${spec%%:*}; rest=${spec#*:}; cnt=${rest%%:*}; mib=${rest##*:}
    total=$(( cnt * mib ))
    p=$( (( mib <= 4 )) && print -- 緩衝 || print -- inline )
    printf '  %-3s %-8s %-6s %-12s %-12s %-9s %-9s %s\n' \
        "$name" "$p" "$cnt" "${MINF[$name]}" \
        "$(( MINF[$name] / total ))" "${MINR[$name]}" "${MINU[$name]}" "${MINS[$name]}"
done
print -- ""
print -- "--- 判讀 / reading it ---"
a=${MINF[A]}; b=${MINF[B]}; c=${MINF[C]}
print -- "  A vs C（位元組數與路徑相同，成員數 32 → 96）: $a → $c"
print -- "  A vs B（位元組數相同，緩衝 → inline）        : $a → $b"
print -- ""
print -- "  若逐檔緩衝是成因：B 應遠低於 A，且 C 應高於 A。"
print -- "  若 B 與 A 相當：該候選被排除，回到零個候選。"
print -- "  If buffering is the cause, B falls far below A and C rises above it."
print -- "  If B matches A, the candidate is excluded."
