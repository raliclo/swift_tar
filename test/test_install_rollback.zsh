#!/usr/bin/env zsh
# test_install_rollback.zsh -- install.zsh puts the old swift_tar back when the new one fails after replacing it
# test_install_rollback.zsh -- 新的 swift_tar 換上去之後才失敗時，install.zsh 會把舊的放回去
#
#   zsh test/test_install_rollback.zsh                      run / 執行
#   INSTALL=/path/to/install.zsh zsh test/...               test another copy / 測另一份
#   zsh test/test_install_rollback.zsh --help               print this synopsis and exit / 印出說明後結束
#
# No network: curl is replaced on PATH by a stub that builds the release archive and its .sha256
# locally, and the "swift_tar" inside is a shell script printing "swift_tar 9.9.9 (fake)". The
# script fails to start in any directory holding a file named FAIL_HERE, so the copy install.zsh
# checks before installing passes and the installed copy fails; that is the case 5011d41's
# rollback is for. Until 5011d41 the failed binary was left installed. Not run on Windows: there
# the archive carries a real .exe and DLLs, which a shell script cannot stand in for.
# 不連網路：PATH 上的 curl 換成一支替身，在本機做出 release 封存與它的 .sha256，裡面的
# 「swift_tar」是一支印出「swift_tar 9.9.9 (fake)」的 shell 腳本。只要所在目錄裡有名為 FAIL_HERE
# 的檔案它就啟動失敗，於是 install.zsh 安裝前檢查的那份通過、裝好的那份失敗；5011d41 的還原就是
# 為這種情況而做。5011d41 之前，失敗的執行檔會留在原處。Windows 上不跑：那裡的封存帶真正的 .exe
# 與 DLL，shell 腳本替代不了。

if [[ ${1:-} == --help || ${1:-} == -h ]]; then sed -n '2,20p' "${0:A}" | sed 's/^# \{0,1\}//'; exit 0; fi

ROOT="${0:A:h:h}"
INSTALL=${INSTALL:-$ROOT/install.zsh}
[[ -r $INSTALL ]] || { print -u2 "error: no $INSTALL / 找不到 $INSTALL"; exit 1 }
case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*) print -r -- "SKIP: Windows (see --help) / 略過：Windows（見 --help）"; exit 0 ;;
esac
for tool in zstd tar; do
  command -v $tool >/dev/null || { print -u2 "error: $tool is not on PATH / PATH 上沒有 $tool"; exit 1 }
done

pass=0 fail=0
ok()  { print -r -- "PASS: $1"; pass=$((pass + 1)) }
bad() { print -r -- "FAIL: $1"; fail=$((fail + 1)) }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/payload" "$TMP/work"

# The new swift_tar, and the old one each case starts from. / 新的 swift_tar，以及各案例起始時的舊版。
print -r -- '#!/bin/sh
[ -e FAIL_HERE ] && { echo "fake swift_tar: told to fail here" >&2; exit 1; }
echo "swift_tar 9.9.9 (fake)"' > "$TMP/payload/swift_tar"
print -r -- '#!/bin/sh
echo "swift_tar 0.0.1 (old)"' > "$TMP/old_swift_tar"
chmod 755 "$TMP/payload/swift_tar" "$TMP/old_swift_tar"

# curl -fsSL -o OUT URL: build OUT from the payload, named as install.zsh asked for it.
# curl -fsSL -o OUT URL：依 install.zsh 要的名稱，用 payload 做出 OUT。
print -r -- '#!/usr/bin/env zsh
out="" url=""
while (( $# )); do
  case $1 in -o) out=$2; shift ;; -*) ;; *) url=$1 ;; esac
  shift
done
name=${url:t}
case $name in
  *.tar.zst)
    stem=${name%.tar.zst}
    rm -rf -- "$FAKE_WORK/$stem" && mkdir -p -- "$FAKE_WORK/$stem" || exit 1
    cp -p -- "$FAKE_PAYLOAD/swift_tar" "$FAKE_WORK/$stem/" || exit 1
    (cd -- "$FAKE_WORK" && tar -cf - "$stem") | zstd -q -c > "$out" ;;
  *.sha256)
    if command -v sha256sum >/dev/null; then h=$(sha256sum -- "${name%.sha256}")
    else h=$(shasum -a 256 -- "${name%.sha256}"); fi
    print -r -- "${h%% *}  ${name%.sha256}" > "$out" ;;
  *) print -ru2 -- "curl stub: unexpected URL [$url]"; exit 22 ;;
esac' > "$TMP/bin/curl"
chmod 755 "$TMP/bin/curl"

# run_install PREFIX: install 9.9.9 into PREFIX/bin; rc in $rc, output in $TMP/out.
# run_install PREFIX：把 9.9.9 裝進 PREFIX/bin；結束碼放 $rc，輸出放 $TMP/out。
run_install() {
  rc=0
  PATH="$TMP/bin:$PATH" FAKE_PAYLOAD="$TMP/payload" FAKE_WORK="$TMP/work" \
    zsh "$INSTALL" 9.9.9 --prefix "$1" > "$TMP/out" 2>&1 || rc=$?
}
# Leftover staging directories from install.zsh. / install.zsh 留下的暫存目錄。
leftovers() { local -a l=( $1/bin/.swift_tar-install.*(DN) ); print -r -- "${l[*]}" }

# 1. Fresh install. / 全新安裝。
P=$TMP/fresh
run_install $P
[[ $rc == 0 && $(cd $P/bin && ./swift_tar --version) == 'swift_tar 9.9.9 (fake)' && -z $(leftovers $P) ]] \
  && ok "fresh install: 9.9.9 in place, nothing left behind" \
  || bad "fresh install: 9.9.9 in place, nothing left behind (rc $rc; left [$(leftovers $P)]; $(<$TMP/out))"

# 2. Over an old one. / 蓋過舊版。
P=$TMP/over && mkdir -p $P/bin && cp -p $TMP/old_swift_tar $P/bin/swift_tar
run_install $P
[[ $rc == 0 && $(cd $P/bin && ./swift_tar --version) == 'swift_tar 9.9.9 (fake)' && -z $(leftovers $P) ]] \
  && ok "over an old one: replaced, nothing left behind" \
  || bad "over an old one: replaced, nothing left behind (rc $rc; left [$(leftovers $P)]; $(<$TMP/out))"

# 3. The installed copy fails its check: the old one comes back, byte for byte.
#    裝好的那份檢查失敗：舊版原樣回來。
P=$TMP/rollback && mkdir -p $P/bin && cp -p $TMP/old_swift_tar $P/bin/swift_tar && : > $P/bin/FAIL_HERE
run_install $P
if [[ $rc != 0 ]] && cmp -s $TMP/old_swift_tar $P/bin/swift_tar && [[ -z $(leftovers $P) ]]; then
  ok "installed copy fails: exits $rc, the old swift_tar is back, nothing left behind"
else
  bad "installed copy fails: the old swift_tar is back (rc $rc; now [$(cd $P/bin && ./swift_tar --version 2>&1)]; left [$(leftovers $P)]; $(<$TMP/out))"
fi
grep -q 'reports \[\]\|does not run' $TMP/out \
  && ok "installed copy fails: the reason is printed" \
  || bad "installed copy fails: the reason is printed ($(<$TMP/out))"

# 4. Same, with nothing installed before: nothing is left installed.
#    同上，但之前沒裝過：結束後也沒有東西留著。
P=$TMP/rollback_fresh && mkdir -p $P/bin && : > $P/bin/FAIL_HERE
run_install $P
[[ $rc != 0 && ! -e $P/bin/swift_tar && -z $(leftovers $P) ]] \
  && ok "installed copy fails on a fresh prefix: exits $rc, no swift_tar left there" \
  || bad "installed copy fails on a fresh prefix: no swift_tar left there (rc $rc; ls [$(ls -A $P/bin)]; $(<$TMP/out))"

print -r -- "-----------------------------------------"
print -r -- "PASS: $pass  FAIL: $fail"
(( fail == 0 ))
