#!/usr/bin/env zsh
# Build a one-member ustar archive with an arbitrary, unsanitised member name.
# Written in zsh rather than perl/python: the only awkward part is the header
# checksum, and that is just a byte sum.
#
#   ./mktar.zsh <out.tar> <member-name> [content]
#
# Every tar CLI sanitises names like "../x" at creation time, so a fixture for
# extraction-time defences cannot be made with one; the header has to be laid
# down directly.
# 每個 tar CLI 都會在建立時清理 "../x" 這類名稱，故測試「解出端防禦」的測資無法用
# 它們產生，必須直接鋪設標頭。
set -euo pipefail

out=${1:?output path}
name=${2:?member name}
content=${3:-traversal payload}

emit_field() {  # value, width -> NUL-padded fixed field
    local v=$1 w=$2
    printf '%s' "$v"
    local pad=$(( w - ${#v} ))
    (( pad > 0 )) && printf '\0%.0s' {1..$pad}
}

size=${#content}
hdr_file=$(mktemp)

{
    emit_field "$name" 100
    emit_field "0000644" 8
    emit_field "0000000" 8
    emit_field "0000000" 8
    emit_field "$(printf '%011o' $size)" 12
    emit_field "$(printf '%011o' 0)" 12
    printf '        '            # checksum field: 8 spaces while summing
    printf '0'                   # typeflag: regular file
    emit_field "" 100            # linkname
    printf 'ustar\0'             # magic
    printf '00'                  # version
    emit_field "" 32             # uname
    emit_field "" 32             # gname
    emit_field "" 8              # devmajor
    emit_field "" 8              # devminor
    emit_field "" 155            # prefix
    emit_field "" 12             # padding to 512
} > "$hdr_file"

# Checksum: unsigned sum of all 512 header bytes with the checksum field as
# spaces, written back as 6 octal digits + NUL + space.
# 檢查和：以檢查和欄位為空白時、全部 512 個標頭位元組的無號總和，寫回為 6 位八進位
# 加上 NUL 與空白。
sum=0
while IFS= read -r byte; do
    [[ -n $byte ]] || continue
    sum=$(( sum + 8#$byte ))
done < <(od -An -to1 -v "$hdr_file" | tr -s ' ' '\n')

{
    head -c 148 "$hdr_file"
    printf '%06o\0 ' $sum
    tail -c +157 "$hdr_file"
    printf '%s' "$content"
    printf '\0%.0s' {1..$(( 512 - size ))}
    printf '\0%.0s' {1..1024}          # two zero blocks: end of archive
} > "$out"

rm -f "$hdr_file"
printf 'built %s: member=[%s] size=%s bytes=%s\n' "$out" "$name" "$size" "$(wc -c < "$out")"
