#!/usr/bin/env zsh
# test_read_codec_flags.zsh -- a codec flag on -x/-t is accepted silently, as tar and bsdtar do
# test_read_codec_flags.zsh -- -x／-t 帶壓縮旗標時安靜接受，與 tar、bsdtar 相同
#
#   zsh test/test_read_codec_flags.zsh          run / 執行
#   zsh test/test_read_codec_flags.zsh --help   print this synopsis and exit / 印出說明後結束
#
# Why: reading auto-detects the codec, so `-x --zstd` has nothing to do; until 2026-11-24 it still
# printed "Note: codec flags only affect -c" on every run. On the LinuxCS VM /usr/bin/tar is a
# wrapper that execs swift_tar, so multiscp, which cannot tell it from GNU tar, extracts with GNU's
# `-x --zstd` and the note appeared on each transfer. GNU tar and bsdtar say nothing there.
# 為什麼：讀取時會自動判斷壓縮格式，所以 `-x --zstd` 沒有事可做；到 2026-11-24 為止它每次仍印出
# 「提示：引擎旗標僅影響 -c」。LinuxCS 虛擬機上的 /usr/bin/tar 是轉手執行 swift_tar 的包裝程式，
# multiscp 分不出它與 GNU tar，便以 GNU 的 `-x --zstd` 解開，於是每次傳輸都出現這行提示。GNU tar
# 與 bsdtar 在這裡都不會多說話。

if [[ ${1:-} == --help || ${1:-} == -h ]]; then sed -n '2,15p' "${0:A}" | sed 's/^# \{0,1\}//'; exit 0; fi

ROOT="${0:A:h:h}"
if [[ -z ${ST:-} ]]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$ROOT/release/swift_tar.exe" ;;
    *) ST="$ROOT/release/swift_tar" ;;
  esac
fi
[[ -x $ST ]] || { print -u2 "error: build first -- missing $ST / 請先建置"; exit 1 }

pass=0 fail=0
ok()  { print -r -- "PASS: $1"; pass=$((pass + 1)) }
bad() { print -r -- "FAIL: $1"; fail=$((fail + 1)) }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
cd -q "$TMP" || exit 1
mkdir src && print -r -- hello > src/a.txt
"$ST" -c -z -f a.tgz src && "$ST" -c --zstd -f a.tzst src || { print -u2 "error: could not create the fixtures"; exit 1 }

# archive, flag given on read. The last two give the wrong flag: reading goes by the magic bytes.
# 封存、讀取時給的旗標。最後兩組給錯旗標：讀取依 magic 位元組判斷。
for case in 'a.tzst --zstd' 'a.tgz -z' 'a.tgz --gzip' 'a.tzst -z' 'a.tgz --zstd'; do
  arc=${case%% *} flag=${case#* }
  rm -rf out && mkdir out
  rc=0; "$ST" -x $flag -f "$arc" -C out 2> err || rc=$?
  [[ $rc == 0 && -z $(<err) && $(<out/src/a.txt) == hello ]] \
    && ok "-x $flag on $arc: extracts, nothing on stderr" \
    || bad "-x $flag on $arc: extracts, nothing on stderr (rc $rc; stderr [$(<err)])"
  rc=0; "$ST" -t $flag -f "$arc" > list 2> err || rc=$?
  [[ $rc == 0 && -z $(<err) ]] && grep -qx 'src/a.txt' list \
    && ok "-t $flag on $arc: lists, nothing on stderr" \
    || bad "-t $flag on $arc: lists, nothing on stderr (rc $rc; stderr [$(<err)])"
done

# From a pipe, as multiscp sends it. / 從管線讀，如同 multiscp 送來的方式。
rm -rf out && mkdir out
rc=0; "$ST" -x --zstd -f - -C out < a.tzst 2> err || rc=$?
[[ $rc == 0 && -z $(<err) && $(<out/src/a.txt) == hello ]] \
  && ok "-x --zstd -f - from a pipe: extracts, nothing on stderr" \
  || bad "-x --zstd -f - from a pipe: extracts, nothing on stderr (rc $rc; stderr [$(<err)])"

# Still refused where they always were: two codec flags. / 原本就拒絕的仍然拒絕：兩個壓縮旗標。
rc=0; "$ST" -x -z --zstd -f a.tgz -C out 2> err || rc=$?
[[ $rc != 0 ]] && grep -q 'at most one codec flag' err \
  && ok "two codec flags on -x are still refused" \
  || bad "two codec flags on -x are still refused (rc $rc; stderr [$(<err)])"

print -r -- "-----------------------------------------"
print -r -- "PASS: $pass  FAIL: $fail"
(( fail == 0 ))
