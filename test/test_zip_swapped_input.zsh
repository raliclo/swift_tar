#!/usr/bin/env zsh
# test_zip_swapped_input.zsh -- parallel -c --zip leaves out a file swapped after it was scanned
# test_zip_swapped_input.zsh -- 平行 -c --zip 略過掃描之後被換掉的檔案
#
#   zsh test/test_zip_swapped_input.zsh          run / 執行
#   ST=/path/to/swift_tar zsh test/...           test another binary / 測另一個執行檔
#   zsh test/test_zip_swapped_input.zsh --help   print this synopsis and exit / 印出說明後結束
#
# With -n 2 a worker thread reads each file some time after the walk listed it. 5011d41 makes the
# worker open without following a symlink (unless -h), without blocking on a FIFO, and refuse
# what it opened unless it is a regular file with the device and inode the walk saw. Before that,
# a file renamed over the listed one was stored under its name, a symlink put in its place was
# followed, and a FIFO hung the run.
# To open that window on purpose, three 60 MiB random files go first: the two workers are busy
# with them for well over a second, while the small file behind them is already listed and
# waiting. It is swapped 0.3 s after the archive appears. If the swap came too late, the original
# bytes are stored, and that is reported as a failure of the setup, not as a pass.
# Not on Windows: there the parallel path is not built and every member is written as it is
# listed, so there is no window.
# 使用 -n 2 時，工作執行緒在走訪列出檔案之後過一段時間才讀它。5011d41 讓工作執行緒開檔時不跟隨
# symlink（除非 -h）、不因 FIFO 阻塞，而且開到的若不是一般檔案、或裝置號與 inode 不是走訪時看到
# 的那個，就拒絕。在那之前，改名蓋過原檔的另一個檔案會以原名存進去、換上的 symlink 會被跟隨、
# FIFO 會讓整次執行卡住。
# 為了刻意打開這個窗口，前面先放三個 60 MiB 的隨機檔：兩個工作執行緒會忙上一秒多，排在後面的
# 小檔這時已列出、正在等。封存檔出現 0.3 秒後替換它。若替換來得太晚，存進去的會是原本的位元組，
# 這會回報為「測試前提沒有成立」的失敗，不會算成通過。
# Windows 上不跑：那裡沒有建置平行路徑，每個成員列出時就寫，沒有這個窗口。

if [[ ${1:-} == --help || ${1:-} == -h ]]; then sed -n '2,25p' "${0:A}" | sed 's/^# \{0,1\}//'; exit 0; fi

ROOT="${0:A:h:h}"
case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*) print -r -- "SKIP: Windows (see --help) / 略過：Windows（見 --help）"; exit 0 ;;
esac
ST=${ST:-$ROOT/release/swift_tar}
[[ -x $ST ]] || { print -u2 "error: build first -- missing $ST / 請先建置"; exit 1 }

pass=0 fail=0
ok()  { print -r -- "PASS: $1"; pass=$((pass + 1)) }
bad() { print -r -- "FAIL: $1"; fail=$((fail + 1)) }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
cd -q "$TMP" || exit 1
for i in 1 2 3; do head -c $((60 * 1024 * 1024)) /dev/urandom > big$i || exit 1; done
# Same length as the original, so whatever was read fits the listed size.
# 與原檔等長，讀到的東西剛好是列出時的大小。
print -r -- 'SECRET!!' > secret
print -r -- 'REPLACED' > other_file

# swap KIND: run swift_tar, replace `target` once the archive exists, wait at most 30 s.
# Sets rc (or "hung"), leaves stderr in err and the archive in out.zip.
# swap KIND：執行 swift_tar，封存檔出現後替換 `target`，最多等 30 秒。
# 設定 rc（或 "hung"），stderr 留在 err，封存留在 out.zip。
swap() {
  rm -f out.zip target err
  print -r -- 'original' > target
  "$ST" -c --zip -n 2 -f out.zip big1 big2 big3 target 2> err &
  local pid=$! t
  for (( t = 0; t < 100; t++ )); do [[ -e out.zip ]] && break; sleep 0.02; done
  sleep 0.3
  rm -f target
  case $1 in
    file)    cp other_file target.new && mv target.new target ;;
    fifo)    mkfifo target ;;
    symlink) ln -s secret target ;;
  esac
  for (( t = 0; t < 300; t++ )); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  if kill -0 $pid 2>/dev/null; then
    kill -9 $pid; wait $pid 2>/dev/null
    rc=hung
  else
    wait $pid; rc=$?
  fi
}

# What the archive holds under `target`: "(absent)", or its bytes.
# 封存裡 `target` 這個名稱存的是什麼：「(absent)」或它的內容。
stored() {
  if [[ $rc == hung || ! -s out.zip ]]; then print -r -- '(no archive)'; return; fi
  if "$ST" -t -f out.zip | grep -qx target; then
    # Whole archive: -x does not take member names for ZIP. / 整包解開：ZIP 的 -x 不接受成員名稱。
    rm -rf x && mkdir x && "$ST" -x -f out.zip -C x && print -r -- "$(<x/target)"
  else
    print -r -- '(absent)'
  fi
}

for kind in file fifo symlink; do
  swap $kind
  got=$(stored)
  if [[ $got == original ]]; then
    bad "$kind swapped in: the swap came after the read, so this run tested nothing (setup) / 替換晚於讀取，這一輪沒測到東西"
  elif [[ $rc != hung && $rc != 0 && $got == '(absent)' ]] && grep -q 'target.*left out' err; then
    ok "$kind swapped in after the scan: left out and named on stderr, exit $rc"
  else
    bad "$kind swapped in after the scan: left out (rc $rc; stored [$got]; stderr [$(<err)])"
  fi
done

print -r -- "-----------------------------------------"
print -r -- "PASS: $pass  FAIL: $fail"
(( fail == 0 ))
