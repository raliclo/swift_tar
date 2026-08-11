#!/usr/bin/env zsh
# Where does swift_tar's extraction time actually go?
#
#   ./verifications/extract_write_path.zsh [output-report]
#
# BACKGROUND
#
# swift_tar extracts a 3.3 GB .tar.gz of large files about 1.7x slower than
# bsdtar. A follow-up run on a subset of the same tree appeared to show 6.3x,
# which suggested the cost scaled with file count -- but that run was taken on
# a sparse disk image with two benchmark processes racing on one scratch
# directory, and it does not reproduce. This script replaces guessing with
# measurement: hold total bytes constant, vary only the file count, on a
# private temp directory.
#
# The answer turned out to be the OPPOSITE of that first guess. See
# verifications/README.md.
#
# 背景：swift_tar 解開由大檔組成的 3.3 GB .tar.gz 約比 bsdtar 慢 1.7 倍。後續
# 在同一棵樹的子集上量到 6.3 倍，看似成本隨檔案數上升——但那一輪是在 sparse
# disk image 上、且有兩個 benchmark 行程在同一個暫存目錄互相踩踏，無法重現。
# 本腳本以量測取代猜測：固定總位元組、只改變檔案數、使用私有暫存目錄。
# 結果與當初的猜測「相反」，詳見 verifications/README.md。
#
# WHAT IT MEASURES
#
#   1. per-file cost      -- same bytes, 8 / 512 / 8192 files
#   2. write-path cost    -- `-t` (decode, no writes) vs `-x` (decode + writes)
#   3. actual parallelism -- CPU time / wall time
#   4. chunked gzip       -- whether --gzip really emits one member per 4 MiB
#
# Point 2 is the one that bounds any future work: parallel file writing can
# only ever recover part of the (-x minus -t) gap. If that gap is small, the
# optimisation is not there.
#
# 第 2 項界定了未來優化的上限：平行寫檔最多只能回收 (-x 減 -t) 這段差距的一部分。
# 若該差距很小，優化空間就不存在。

emulate -L zsh
setopt no_unset pipe_fail null_glob

HERE=${0:A:h}
ST=${SWIFT_TAR:-$HERE/../release/swift_tar}
BSDTAR=${BSDTAR:-/usr/bin/tar}
TOTAL=${TOTAL_BYTES:-$((256 * 1024 * 1024))}

[[ -x $ST ]] || { print -ru2 -- "no swift_tar at $ST (set SWIFT_TAR=)"; exit 1 }

# A private work directory. Two concurrent runs sharing one scratch directory
# produced impossible numbers once (a 512 MiB extraction "taking" 8ms) because
# each was deleting the other's corpus mid-measurement. mktemp -d makes that
# structurally impossible rather than merely unlikely.
# 私有工作目錄。曾有兩個並行執行共用同一個暫存目錄，產生出不可能的數字（512 MiB
# 解壓「只花」8ms），因為彼此在對方量測到一半時刪掉了語料。用 mktemp -d 讓這件事
# 在結構上不可能發生，而不只是「不太可能」。
B=$(mktemp -d "${TMPDIR:-/tmp}/swifttar-wp.XXXXXX")
trap 'rm -rf $B' EXIT INT TERM

# Repo convention: <name>.sh alongside <name>_output.txt.
# 本 repo 慣例：<name>.sh 與 <name>_output.txt 並排。
REPORT=${1:-$HERE/extract_write_path_output.txt}
mkdir -p ${REPORT:h}

typeset -a OUT
say() { print -r -- "$1"; OUT+=("$1") }

say "# swift_tar extraction: where the time goes"
say "date      : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "swift_tar : $($ST --version 2>&1 | head -1)"
say "bsdtar    : $($BSDTAR --version 2>&1 | head -1)"
say "host      : $(uname -srm), $(getconf _NPROCESSORS_ONLN 2>/dev/null || print '?') cores"
say "total     : $((TOTAL / 1024 / 1024)) MiB per corpus"
say ""

# --- corpus ---------------------------------------------------------------
# Half random, half text. Fully random would make gzip a no-op and hide the
# decode cost; fully text would compress ~1000x and hide the I/O.
# 一半隨機、一半文字。全隨機會讓 gzip 形同無作用而掩蓋解碼成本；全文字壓縮率過高
# 而掩蓋 I/O。
blob=$B/blob.bin
head -c $((TOTAL / 2)) /dev/urandom > $blob
yes 'the quick brown fox jumps over the lazy dog 0123456789' | head -c $((TOTAL / 2)) >> $blob 2>/dev/null

# ms wall clock
t() { local s=$(date +%s%N); "$@" >/dev/null 2>&1; print -- $(( ($(date +%s%N) - s) / 1000000 )) }

# "wall user sys" in ms -- CPU/wall > 1 means more than one core was busy
# "wall user sys"（毫秒）。CPU/wall > 1 表示不只一個核心在忙。
cpu() {
  local tf=$B/.time
  { /usr/bin/time -p "$@" ; } 2>$tf >/dev/null
  LC_ALL=C awk '/^real/{r=$2}/^user/{u=$2}/^sys/{s=$2}
       END{printf "%d %d %d", r*1000, u*1000, s*1000}' $tf
}

say "## 1. per-file cost (total bytes held constant)"
say ""
say "corpus     files  avg size |  bsdtar -c  bsdtar -x |  swift -c   swift -x   x ratio"
say "---------------------------------------------------------------------------------"

typeset -A XTIME
for spec in "few:$((32 * 1024 * 1024))" "mid:$((512 * 1024))" "many:$((32 * 1024))"; do
  name=${spec%%:*} fsz=${spec##*:}
  d=$B/c-$name; mkdir -p $d
  split -b $fsz -a 6 $blob $d/f
  nf=$(ls $d | wc -l | tr -d ' ')

  bc=$(t $BSDTAR -czf $B/$name.bsd.tgz -C $d .)
  sc=$(t $ST -c --gzip -f $B/$name.sw.tgz -C $d .)

  rm -rf $B/x; mkdir -p $B/x
  bx=$(t $BSDTAR -xzf $B/$name.bsd.tgz -C $B/x)
  rm -rf $B/x; mkdir -p $B/x
  sx=$(t $ST -x -f $B/$name.sw.tgz -C $B/x)
  rm -rf $B/x

  XTIME[$name]=$sx
  say "$(printf '%-10s %5s %9s | %9sms %9sms | %8sms %9sms %8.1fx' \
      $name $nf "$((fsz / 1024))K" $bc $bx $sc $sx \
      $(( sx * 1.0 / (bx > 0 ? bx : 1) )))"

  rm -rf $d
done

say ""
say "If the ratio grows as files get smaller, the cost is per-FILE, not per-byte."
say "若比值隨檔案變小而上升，成本就在「每個檔案」而非「每位元組」。"

# --- 2. write path --------------------------------------------------------
say ""
say "## 2. how much of extraction is the write path"
say ""
say "-t decodes the whole archive and writes nothing. -x does the same decode"
say "plus the file creation. The difference is the write path, and it is the"
say "ceiling on what parallel writing could ever recover."
say "-t 解開整個封存但不寫任何檔；-x 是同樣的解碼再加上建檔。兩者之差即為寫檔"
say "路徑的成本，也是平行寫檔所能回收的上限。"
say ""
say "corpus     files |   swift -t   swift -x  write path | bsdtar -t bsdtar -x  write path"
say "--------------------------------------------------------------------------------------"

for spec in "few:$((32 * 1024 * 1024))" "many:$((32 * 1024))"; do
  name=${spec%%:*} fsz=${spec##*:}
  d=$B/c-$name; mkdir -p $d
  split -b $fsz -a 6 $blob $d/f
  nf=$(ls $d | wc -l | tr -d ' ')
  $ST -c --gzip -f $B/$name.sw.tgz -C $d . >/dev/null 2>&1
  $BSDTAR -czf $B/$name.bsd.tgz -C $d . 2>/dev/null

  st_t=$(t $ST -t -f $B/$name.sw.tgz)
  rm -rf $B/x; mkdir -p $B/x
  st_x=$(t $ST -x -f $B/$name.sw.tgz -C $B/x)
  bt_t=$(t $BSDTAR -tzf $B/$name.bsd.tgz)
  rm -rf $B/x; mkdir -p $B/x
  bt_x=$(t $BSDTAR -xzf $B/$name.bsd.tgz -C $B/x)
  rm -rf $B/x $d

  say "$(printf '%-10s %5s | %9sms %9sms %9sms | %7sms %8sms %9sms' \
      $name $nf $st_t $st_x $((st_x - st_t)) $bt_t $bt_x $((bt_x - bt_t)))"
done

# --- 3. parallelism -------------------------------------------------------
say ""
say "## 3. is more than one core actually used"
say ""
say "CPU/wall near 1.0 means single-threaded regardless of what -n was set to."
say "CPU/wall 接近 1.0 表示實際為單執行緒，與 -n 設定無關。"
say ""
say "operation                  wall     user      sys   CPU/wall"
say "-------------------------------------------------------------"

d=$B/c-par; mkdir -p $d
split -b $((32 * 1024)) -a 6 $blob $d/f
$ST -c --gzip -f $B/par.sw.tgz -C $d . >/dev/null 2>&1
$BSDTAR -czf $B/par.bsd.tgz -C $d . 2>/dev/null

row() {  # row <label> <cmd...>
  local label=$1; shift
  rm -rf $B/x; mkdir -p $B/x
  local r=($(cpu "$@"))
  say "$(printf '%-24s %6sms %6sms %6sms %8.2f' \
      $label $r[1] $r[2] $r[3] $(( ($r[2] + $r[3]) * 1.0 / ($r[1] > 0 ? $r[1] : 1) )))"
}
row "swift -x (default -n)" $ST -x -f $B/par.sw.tgz -C $B/x
row "swift -x -n 1"         $ST -x -n 1 -f $B/par.sw.tgz -C $B/x
row "swift -x -n 8"         $ST -x -n 8 -f $B/par.sw.tgz -C $B/x
row "swift -t (decode only)" $ST -t -f $B/par.sw.tgz
row "bsdtar -x"             $BSDTAR -xzf $B/par.bsd.tgz -C $B/x
rm -rf $B/x $d

# --- 4. chunked gzip ------------------------------------------------------
say ""
say "## 4. does --gzip really emit one member per 4 MiB"
say ""
say "gzip -l CANNOT answer this: it reads the first header and the trailing 4"
say "bytes only, so its output is always 2 lines no matter how many members"
say "there are. The stream has to be walked member by member."
say "gzip -l 無法回答這個問題：它只讀第一個 header 與結尾 4 bytes，輸出永遠是"
say "兩行，與成員數無關。必須逐一走訪整個串流。"
say ""

d=$B/c-mem; mkdir -p $d
split -b $((8 * 1024 * 1024)) -a 6 $blob $d/f
$ST -c --gzip -f $B/mem.sw.tgz -C $d . >/dev/null 2>&1
$BSDTAR -czf $B/mem.bsd.tgz -C $d . 2>/dev/null

mem_out=$(python3 - $B/mem.bsd.tgz $B/mem.sw.tgz <<'PY'
import sys, zlib
for path in sys.argv[1:]:
    data = open(path, 'rb').read()
    off, n, outs = 0, 0, []
    while off < len(data):
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        try:
            out = d.decompress(data[off:])
        except zlib.error as e:
            print(f"  ! member {n+1} @{off}: {e}")
            break
        n += 1
        outs.append(len(out))
        off += len(data) - off - len(d.unused_data)
        if not d.unused_data:
            break
    label = path.split('/')[-1]
    print(f"  {label:18s} members={n:5d}  uncompressed/member: "
          f"min={min(outs):,} max={max(outs):,}")
PY
)
say "$mem_out"
rm -rf $d

say ""
say "4 MiB = 4,194,304. A max of exactly that across many members is the"
say "pigz-style chunking working as documented."
say "4 MiB = 4,194,304。多個成員的最大值正好是這個數字，即代表 pigz 式分塊如"
say "文件所述正常運作。"

print -rl -- $OUT > $REPORT
print -r -- ""
print -r -- "report: $REPORT"
