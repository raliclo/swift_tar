#!/usr/bin/env zsh
# submodule_pins.zsh -- sourced by the build scripts: check out a submodule only when it is not
# checked out yet, and refuse to build one sitting at a commit other than the one recorded.
# submodule_pins.zsh -- 由建置腳本 source：子模組尚未 checkout 時才 checkout；若它停在與記錄
# 不同的 commit，就拒絕建置。
#
#   . ./submodule_pins.zsh
#   ensure_submodule_pins libarchive zlib || exit 1
#
# The build scripts used to run `git submodule update --init <names>` unconditionally. That
# moves every submodule to the commit recorded in the index, so a submodule deliberately
# checked out elsewhere -- by sync_all.zsh --update, or by hand to try a newer codec -- was put
# back without a word, and the build and every test then ran on the old code. On 2026-10-19 a
# whole WSL suite (692/0) "verified" libarchive 7f149b1, lz4 779b355 and xz 299eb5c that way
# while building b8189c9, 664c914 and b355a31; only version-linux.txt still naming the old
# commits gave it away. Now: not checked out -> check it out as before; at the recorded commit
# -> nothing to do; anywhere else -> stop and say how to choose. "Recorded" is the gitlink in the
# index (what `git submodule update` uses), so a staged bump builds without being committed.
#
# 建置腳本原本無條件執行 `git submodule update --init <名稱>`。它會把每個子模組移到索引記錄的
# commit，於是刻意 checkout 到別處的子模組——被 sync_all.zsh --update 移動，或手動 checkout 來試
# 新版 codec——會被無聲地放回去，建置與所有測試接著都跑在舊程式碼上。2026-10-19 一整套 WSL 測試
# （692/0）就這樣「驗證」了 libarchive 7f149b1、lz4 779b355、xz 299eb5c，實際建的卻是 b8189c9、
# 664c914、b355a31；露出破綻的只有 version-linux.txt 仍寫著舊 commit。現在：尚未 checkout → 照舊
# checkout；正在記錄的 commit → 不動；在其他地方 → 停下並說明如何選擇。「記錄」指索引中的
# gitlink（`git submodule update` 依據的就是它），所以暫存的升級不必先提交就能建置。

ensure_submodule_pins() {  # <submodule>...
  local m recorded actual bad=0
  for m in "$@"; do
    if [[ ! -e $m/.git ]]; then
      git submodule update --init -- "$m" || return 1
      continue
    fi
    recorded=$(git rev-parse ":$m") || return 1
    actual=$(git -C "$m" rev-parse HEAD) || return 1
    [[ $actual == $recorded ]] && continue
    printf '%s\n' \
      "[FAIL] $m is checked out at ${actual[1,9]} but swift_tar records ${recorded[1,9]}; not building either." \
      "       To build ${actual[1,9]}: git add $m   (staging is enough; commit after verifying)" \
      "       To go back to ${recorded[1,9]}: git submodule update -- $m" \
      "[FAIL] $m 目前 checkout 在 ${actual[1,9]}，但 swift_tar 記錄的是 ${recorded[1,9]}；兩者都不建置。" \
      "       要建置 ${actual[1,9]}：git add $m（暫存即可，驗證後再提交）" \
      "       要回到 ${recorded[1,9]}：git submodule update -- $m" >&2
    bad=1
  done
  (( bad == 0 ))
}
