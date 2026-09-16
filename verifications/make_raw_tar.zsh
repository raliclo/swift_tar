#!/usr/bin/env zsh
# Build a ustar archive with arbitrary, unsanitised member names and types.
# 以任意且未經清理的成員名稱與型別建立 ustar 封存。
#
#   ./make_raw_tar.zsh <out.tar> file <name> <content>
#   ./make_raw_tar.zsh <out.tar> link <name> <linkname>      # symlink
#   ./make_raw_tar.zsh <out.tar> hard <name> <linkname>      # hardlink
#   ./make_raw_tar.zsh <out.tar> link <name> <linkname> file <name> <content> ...
#   RAW_TAR_MTIME=452013710000 ./make_raw_tar.zsh <out.tar> file <name> <content>
#   ./make_raw_tar.zsh --help
#
# Every tar CLI sanitises names like "../x" at creation time, so a fixture for
# testing extraction-time defences cannot be produced with one; the header has to
# be laid down directly. Written in zsh -- the only awkward part is the header
# checksum, and that is just a byte sum.
# 每個 tar CLI 都會在建立時清理 "../x" 這類名稱，故測試「解出端防禦」的測資無法用它們
# 產生，必須直接鋪設標頭。以 zsh 撰寫——唯一麻煩處是標頭檢查和，而那只是位元組加總。
#
# Two entries in one archive matter: a symlink alone is inert, but a symlink
# followed by a member whose path goes through it is how an archive writes
# outside the destination.
# 「一個封存兩個項目」很重要：單獨的 symlink 是惰性的，但「symlink 之後接一個路徑穿過
# 它的成員」正是封存寫到目的地之外的方式。
#
# RAW_TAR_MTIME, if set, is written verbatim into every entry's 12-byte mtime field
# as octal digits (default: zero). Twelve digits fill the field with no terminator,
# which GNU tar and swift_tar's reader both accept, and reach year 4147 -- past the
# 3000-12-31 limit of the Windows CRT's _futime64. It exists because neither usual
# route produces such an archive: swift_tar's reader ignores a pax `mtime=` record,
# and its writer truncates the field to 11 digits (both measured 2026-09-17).
# 若設定 RAW_TAR_MTIME，它會以八進位數字原樣寫入每個項目 12 位元組的 mtime 欄位（預設為
# 零）。12 位數字填滿欄位且不帶結尾字元，GNU tar 與 swift_tar 讀取端皆接受，可達 4147 年
# ——超過 Windows CRT `_futime64` 的 3000-12-31 上限。之所以需要它，是因為兩條常見途徑
# 都造不出這種封存：swift_tar 讀取端會忽略 pax 的 `mtime=` 記錄，而其寫入端會把該欄位
# 截成 11 位數（兩者皆於 2026-09-17 實測）。
set -euo pipefail

script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,13p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

out=${1:?output path}
shift

# `if`, not `(( pad > 0 )) && printf`: as the last command, that list makes the function
# return 1 whenever a value fills its field exactly, and `set -e` then ends the script
# with rc=1 and a zero-byte archive, printing nothing. No caller passed a full-width
# value until RAW_TAR_MTIME's twelve digits did (2026-09-17).
# 用 `if` 而非 `(( pad > 0 )) && printf`：後者作為最後一個指令，會在值剛好填滿欄位時讓
# 函式回傳 1，`set -e` 隨即以 rc=1 結束腳本並留下 0 位元組的封存，且不印任何訊息。在
# RAW_TAR_MTIME 的 12 位數之前，沒有呼叫者傳過滿寬的值（2026-09-17）。
emit_field() { local v=$1 w=$2; printf '%s' "$v"; local pad=$(( w - ${#v} )); if (( pad > 0 )); then printf '\0%.0s' {1..$pad}; fi; }

# One 512-byte header plus its data blocks, appended to $out.
# 一個 512 位元組標頭與其資料區塊，附加至 $out。
emit_entry() {
    local kind=$1 name=$2 arg=$3
    local typeflag linkname content size
    case $kind in
        file) typeflag='0'; linkname=''; content=$arg; size=${#content} ;;
        link) typeflag='2'; linkname=$arg; content='';  size=0 ;;
        hard) typeflag='1'; linkname=$arg; content='';  size=0 ;;
        # A FIFO carries no data and no link target -- the header alone is the
        # whole entry. / FIFO 不帶資料也無連結目標——整個項目就只有標頭。
        fifo) typeflag='6'; linkname=''; content='';  size=0 ;;
        # A pax extended header: typeflag 'x', payload is "<len> key=value\n"
        # where <len> counts its own digits. The caller passes "key=value" and
        # the length is computed here, because getting that self-reference wrong
        # produces a header every tar silently ignores -- which would look like
        # the reader defending itself.
        # pax 擴充標頭：typeflag 'x'，內容為 "<len> key=value\n"，其中 <len> 包含自身
        # 的位數。呼叫端傳入 "key=value"，長度在此計算——因為算錯這個自我指涉會產生一個
        # 所有 tar 都會靜默忽略的標頭，而那看起來會很像「讀取端擋下了它」。
        pax)
            typeflag='x'; linkname=''
            local body=" $arg"$'\n' len=0 n=1
            while (( len != n )); do n=$len; len=$(( ${#body} + ${#n} )); done
            content="${len}${body}"; size=${#content} ;;
        # GNU long name / long link: typeflag 'L' / 'K', payload is the name.
        # GNU 長名稱／長連結：typeflag 'L'／'K'，內容即為該名稱。
        gnuname) typeflag='L'; linkname=''; content="$arg"$'\0'; size=${#content} ;;
        gnulink) typeflag='K'; linkname=''; content="$arg"$'\0'; size=${#content} ;;
        *) print -ru2 -- "unknown entry kind: $kind"; exit 1 ;;
    esac

    local hdr; hdr=$(mktemp)
    {
        emit_field "$name" 100
        emit_field "0000644" 8
        emit_field "0000000" 8
        emit_field "0000000" 8
        emit_field "$(printf '%011o' $size)" 12
        emit_field "${RAW_TAR_MTIME:-$(printf '%011o' 0)}" 12
        printf '        '
        printf '%s' "$typeflag"
        emit_field "$linkname" 100
        printf 'ustar\0'; printf '00'
        emit_field "" 32; emit_field "" 32
        emit_field "" 8;  emit_field "" 8
        emit_field "" 155
        emit_field "" 12
    } > "$hdr"

    local sum=0 byte
    while IFS= read -r byte; do
        [[ -n $byte ]] || continue
        sum=$(( sum + 8#$byte ))
    done < <(od -An -to1 -v "$hdr" | tr -s ' ' '\n')

    {
        head -c 148 "$hdr"
        printf '%06o\0 ' $sum
        tail -c +157 "$hdr"
        if (( size > 0 )); then
            printf '%s' "$content"
            printf '\0%.0s' {1..$(( 512 - size ))}
        fi
    } >> "$out"
    rm -f "$hdr"
}

: > "$out"
while (( $# >= 3 )); do
    emit_entry "$1" "$2" "$3"
    shift 3
done
printf '\0%.0s' {1..1024} >> "$out"   # two zero blocks: end of archive
printf 'built %s (%s bytes)\n' "$out" "$(wc -c < "$out")"
