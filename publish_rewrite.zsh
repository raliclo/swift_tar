#!/usr/bin/env zsh
# publish_rewrite.zsh -- the package-file rewrite that publish.zsh does, sourced by publish.zsh and
# by test/test_release.zsh, so the step most able to go wrong silently is tested without publishing.
# The caller defines VERSION, base_url, say and die.
# publish_rewrite.zsh -- publish.zsh 改寫套件檔的部分；由 publish.zsh 與 test/test_release.zsh 共同
# source，讓最可能靜默出錯的這一步不必真的發布就能測。呼叫端要定義 VERSION、base_url、say 與 die。

# Which lines carry a version as data and which only talk about one. Prose (Ruby comments,
# scoop's "notes") records history, and history does not move with a release; csv2 shipped a
# self-contradicting sentence before telling them apart. One definition serves the rewrite and
# the stale-version read-back, so neither can fail what the other leaves correct.
# 哪些行把版本號當資料，哪些只是在談論它。散文（Ruby 註解、scoop 的 "notes"）記的是歷史，歷史不隨
# 出貨前進；csv2 在分清兩者之前出貨過一句自相矛盾的話。改寫與「不得殘留舊版本」的讀回共用一份
# 定義，於是一方留對的東西，另一方不會判它失敗。
prose_lines() {   # prose_lines <file> <rb|json>
  setopt local_options extended_glob
  local file=$1 kind=$2 line trimmed
  integer n=0 in_notes=0
  while IFS= read -r line || [[ -n $line ]]; do
    n+=1
    trimmed=${line##[[:space:]]#}
    case $kind in
      rb) [[ $trimmed == '#'* ]] && print -r -- $n ;;
      json)
        if (( in_notes )); then
          print -r -- $n; [[ $trimmed == ']'* ]] && in_notes=0
        elif [[ $trimmed == '"notes"'* ]]; then
          print -r -- $n; [[ $line == *']'* || $line != *'['* ]] || in_notes=1
        fi ;;
    esac
  done < $file
}
data_text() {   # data_text <file> <kind> -- the file without its prose lines
  local file=$1 kind=$2 line ln
  local -A p
  integer n=0
  for ln in ${(f)"$(prose_lines $file $kind)"}; do [[ -n $ln ]] && p[$ln]=1; done
  while IFS= read -r line || [[ -n $line ]]; do
    n+=1; [[ -n ${p[$n]-} ]] || print -r -- "$line"
  done < $file
}
rewrite_version() {   # rewrite_version <file> <kind>
  setopt local_options extended_glob
  local file=$1 kind=$2 line old="" ln tmpf left
  local -A prose
  integer lineno=0 n=0
  for ln in ${(f)"$(prose_lines $file $kind)"}; do [[ -n $ln ]] && prose[$ln]=1; done
  # The first X.Y.Z on a data line mentioning "version".
  # 提到 "version" 的資料行上的第一個 X.Y.Z。
  while IFS= read -r line; do
    lineno+=1
    [[ -n ${prose[$lineno]-} || $line != *version* ]] && continue
    # A regex, not `(#b)*(X.Y.Z)*`: that glob's leading `*` took as much as it could, so
    # "10.2.3" captured "0.2.3". =~ finds the leftmost match and extends it as far as it goes.
    # 用正規式而非 `(#b)*(X.Y.Z)*`：那個 glob 開頭的 `*` 會盡量多吃，於是 "10.2.3" 抓到的是
    # "0.2.3"。=~ 找最左邊的符合處，並盡量延伸。
    [[ $line =~ '[0-9]+\.[0-9]+\.[0-9]+' ]] || continue
    old=$MATCH; break
  done < $file
  [[ -n $old ]] || die "${file:t}: no version line" "${file:t}：找不到版本行"
  [[ $old == $VERSION ]] && return 0
  tmpf=$file.rewriting.$$
  : > $tmpf
  lineno=0
  while IFS= read -r line || [[ -n $line ]]; do
    lineno+=1
    if [[ -z ${prose[$lineno]-} && $line == *$old* ]]; then line=${line//$old/$VERSION}; n+=1; fi
    print -r -- "$line" >> $tmpf
  done < $file
  left=$(data_text $tmpf $kind | LC_ALL=C grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | LC_ALL=C sort -u | LC_ALL=C grep -vxF -- "$VERSION" || true)
  if (( n == 0 )) || [[ -n $left ]]; then
    rm -f $tmpf
    die "${file:t}: rewriting $old -> $VERSION changed $n line(s) and left ${left//$'\n'/ }; not adopted" \
        "${file:t}：把 $old 改成 $VERSION 動了 $n 行，卻留下 ${left//$'\n'/ }；不採用"
  fi
  mv -- $tmpf $file
  say "    ${file:t}: $old -> $VERSION on $n line(s)"
}
# One url and one quoted sha256 after it per platform; a url carrying a literal $version is a
# scoop autoupdate template and is left alone.
# 每個平台恰好一個 url，以及其後一個帶引號的 sha256；含字面 $version 的 url 是 scoop 的 autoupdate
# 模板，不動。
rewrite_pair() {   # rewrite_pair <file> <archive basename> <sha256>
  setopt local_options extended_glob
  local file=$1 base=$2 h=$3 tmpf line pre post
  local url=$base_url/$base plat=${${2#swift_tar-$VERSION-}%.tar.zst}
  integer n_url=0 n_hash=0 pending=0
  tmpf=$file.rewriting.$$
  : > $tmpf
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == *https://github.com/*-${plat}.tar.zst* && $line != *'$version'* ]]; then
      pre=${line%%https://*}; post=${line#*.tar.zst}
      line=$pre$url$post; n_url+=1; pending=1
    elif (( pending )) && [[ $line == *\"[0-9a-f](#c64)\"* ]]; then
      line=${line/\"[0-9a-f](#c64)\"/\"$h\"}; n_hash+=1; pending=0
    fi
    print -r -- "$line" >> $tmpf
  done < $file
  if (( n_url != 1 || n_hash != 1 )); then
    rm -f $tmpf
    die "${file:t}: expected one url and one sha256 for $plat, rewrote $n_url and $n_hash" \
        "${file:t}：$plat 應該只有一個 url 與一個 sha256，實際改寫了 $n_url 與 $n_hash"
  fi
  mv -- $tmpf $file
}

