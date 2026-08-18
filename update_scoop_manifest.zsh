#!/usr/bin/env zsh
# update_scoop_manifest.zsh -- refresh a scoop manifest's hash after rebuilding its zip
# update_scoop_manifest.zsh -- 重建 zip 後，更新 scoop manifest 中的 hash
#
#   ./update_scoop_manifest.zsh --zip release/swift_tar_win.zip --manifest <manifest.json>
#   ./update_scoop_manifest.zsh --help
#
# Only `architecture.64bit.hash` is touched. The version is left alone: this
# project has no semver or release-tag process yet, so bumping it here would be
# a guess.
# 僅更動 `architecture.64bit.hash`。version 不動：本專案尚無 semver 或 release tag
# 流程，在此調整版本號只是猜測。
#
# The hash is replaced by a surgical text substitution rather than by parsing and
# re-serialising the JSON. A re-serialiser reorders keys, changes indentation and
# escapes punctuation, which would turn every release into a whole-file diff.
# hash 以精準的文字取代完成，而非解析後重新序列化 JSON。重新序列化會重排鍵、改變縮排
# 並轉義標點，使每次發布都變成整檔差異。
set -euo pipefail
# Required by the `(#c64)` repeat-count and `(#b)` backreference forms used
# below. Without it those are ordinary characters, the patterns silently fail to
# match, and the script rejects a hash it had computed correctly.
# 下方使用的 `(#c64)` 重複次數與 `(#b)` 反向參照語法皆需要此選項。未啟用時它們只是
# 普通字元，樣式會無聲地比對不到，導致腳本拒絕一個它其實已正確算出的雜湊。
setopt extendedglob

script_path="${0:A}"

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,16p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

zip=""
manifest=""
while (( $# )); do
  case $1 in
    --zip)      zip=${2:?--zip needs a path};      shift 2 ;;
    --manifest) manifest=${2:?--manifest needs a path}; shift 2 ;;
    *) print -ru2 -- "unknown option: $1 (try --help)"; exit 1 ;;
  esac
done

die() { print -ru2 -- "update_scoop_manifest: $1"; exit 1 }

[[ -n $zip ]]      || die "--zip is required"
[[ -n $manifest ]] || die "--manifest is required"
[[ -f $zip ]]      || die "not found: $zip"
[[ -f $manifest ]] || die "not found: $manifest"

# Feed the file on stdin so the tool prints the digest alone. Given a path it
# prints "<digest>  <path>" -- and in binary mode "<digest> *<path>" -- so the
# trailing field has to be stripped, which is one more thing to get wrong for no
# benefit. Measured: the path form returned "657f... *z.zip" and the digest guard
# below rejected it, correctly leaving the manifest untouched.
# 以 stdin 餵入檔案，讓工具只印出摘要。若改為傳入路徑，它會印出
# 「<digest>  <path>」——二進位模式下更是「<digest> *<path>」——因而必須剝除尾段欄位，
# 徒增一處可能出錯之處而毫無好處。實測：傳路徑的寫法回傳 "657f... *z.zip"，被下方的
# 摘要格式守門擋下，manifest 正確地未被更動。
if (( $+commands[sha256sum] )); then
  new_hash=$(sha256sum < "$zip")
elif (( $+commands[shasum] )); then
  new_hash=$(shasum -a 256 < "$zip")
else
  die "no sha256sum or shasum on PATH"
fi
new_hash=${${new_hash%% *}:l}
[[ $new_hash == [0-9a-f](#c64) ]] || die "unexpected hash: $new_hash"

content=$(<"$manifest")
# `$(<file)` strips every trailing newline, so remember whether the file ended
# with one and put exactly that back. Writing the content as-is cost the file its
# final newline on the first run -- 806 bytes became 805 -- which is precisely the
# gratuitous diff this script exists to avoid.
# `$(<file)` 會剝除所有結尾換行，故先記住原檔是否以換行結尾，最後原樣補回。若直接
# 寫回內容，首次執行就會讓檔案少掉最後的換行——806 bytes 變成 805——而那正是本腳本
# 存在的目的所要避免的無謂差異。
if [[ $(tail -c 1 -- "$manifest" | od -An -c | tr -d ' \n') == '\n' ]]; then
  trailing_newline=1
else
  trailing_newline=0
fi

old_hash=$(grep -o '"hash"[[:space:]]*:[[:space:]]*"[0-9a-f]\{64\}"' -- "$manifest" | head -1 | grep -o '[0-9a-f]\{64\}') || true
[[ -n ${old_hash:-} ]] || die "no 64-hex hash field found in $manifest"

new_content=${content//(#b)(\"hash\"[[:space:]]#:[[:space:]]#\")[0-9a-f](#c64)\"/${match[1]}${new_hash}\"}
if [[ $new_content == "$content" && $old_hash != $new_hash ]]; then
  die "hash field not replaced in $manifest"
fi

# No BOM: scoop reads this as plain UTF-8 and a BOM would be another unasked-for
# diff.
# 不加 BOM：scoop 以純 UTF-8 讀取本檔，加上 BOM 同樣是無人要求的差異。
if (( trailing_newline )); then
  print -r -- "$new_content" > "$manifest"
else
  print -rn -- "$new_content" > "$manifest"
fi

if [[ $old_hash == $new_hash ]]; then
  print -r -- "No change: $manifest hash already $new_hash"
else
  print -r -- "Updated $manifest"
  print -r -- "  old hash: ${old_hash:-<none>}"
  print -r -- "  new hash: $new_hash"
fi
