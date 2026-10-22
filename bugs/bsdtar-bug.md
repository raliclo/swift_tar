# bsdtar on Windows loses siblings after an unstattable entry

**bsdtar aborts a directory walk at the first entry it cannot `stat` and silently
omits every sibling after it, while reporting `Error exit delayed from previous
errors` — wording that claims the opposite.** On Windows the entry that triggers
this needs no malice: an ordinary `ln -s` run under WSL is enough.

**bsdtar 在遇到第一個 `stat` 不到的項目時放棄整個目錄走訪，靜默丟掉其後所有兄弟項目，
同時印出 `Error exit delayed from previous errors`——而這句話的字面意思正好相反。** 在
Windows 上，觸發它不需要任何惡意：在 WSL 下跑一次普通的 `ln -s` 就夠了。

- Measured 2026-10-22 on Windows 11 10.0.26300.9711
- `bsdtar 3.8.9 - libarchive 3.8.9` (`C:\Windows\System32\tar.exe`, the one Microsoft ships)
- `tar (GNU tar) 1.35` (MSYS2)
- `swift_tar 0.1.1 (v0.1.1-4-gc859c228)`

This is recorded here rather than in the README because it is a finding about the
reference implementations, not about this tool. It is kept because it was the
reason a `swift_tar` design decision got re-examined and **confirmed** rather than
changed — see [Why this mattered here](#why-this-mattered-here).

此處記錄的是關於參照實作的發現，而非本工具的行為，故不放在 README。保留它的原因是：它讓
`swift_tar` 的一個設計決定被重新檢視，而結論是**確認**而非改動——見下方〈此事為何與本專案
有關〉。

---

## The entry: an LX reparse point

`ln -s` under WSL (and MSYS without `winsymlinks:nativestrict`) does not create a
native NT symlink. It creates a reparse point tagged `IO_REPARSE_TAG_LX_SYMLINK`
(`0xa000001d`), and **NT will not traverse one at all**:

WSL 下的 `ln -s`（以及未設 `winsymlinks:nativestrict` 的 MSYS）不會建立原生 NT symlink，
而是建立一個 tag 為 `IO_REPARSE_TAG_LX_SYMLINK`（`0xa000001d`）的 reparse point，而
**NT 完全不會穿過這種連結**：

```console
> fsutil reparsepoint query dlink
Reparse Tag Value : 0xa000001d
Tag value: Microsoft
Tag value: Name Surrogate

> dir
10/22/2026  01:12 PM    <JUNCTION>     dlink [...]     <- empty target, and
               3 Dir(s)                                   it is not counted

> type dlink\f.txt
The file cannot be accessed by the system.
```

So any `stat`-like call on such a path fails. That is the platform's behaviour, not
a bug in either tar. What the two reference implementations *do* about it differs,
and one of them loses data.

因此任何對該路徑的 `stat` 類呼叫都會失敗。那是平台行為，不是任一 tar 的缺陷。兩個參照實作
對此的**處理方式**不同，而其中一個會遺失資料。

## Reproduction

Needs WSL (for the LX links) and all three binaries. Nothing below writes outside
its own temporary directory.

需要 WSL（用來產生 LX 連結）與三個執行檔。以下任何步驟都不會寫到自己的暫存目錄之外。

```zsh
#!/usr/bin/env zsh
# bsdtar-bug repro -- three tars, four fixtures, -c -h on each.
# bsdtar-bug 重現 -- 三個 tar、四組測資，各跑 -c -h。
set -euo pipefail
TMP=${1:-./bsdtar-bug-repro}                  # pass a directory, or use this one
rm -rf "$TMP"; mkdir -p "$TMP"

# The same directory as WSL sees it. `cygpath -m` first, NOT `cygpath -w`: a
# backslash is eaten crossing Git Bash -> wsl.exe, so a `C:\...` path arrives at
# wslpath as `C:Users...` and the conversion silently yields an empty string.
# Measured 2026-10-22. MSYS2_ARG_CONV_EXCL is required for every wsl.exe call.
# 同一個目錄在 WSL 眼中的樣子。先用 `cygpath -m` 而非 `cygpath -w`：反斜線跨越
# Git Bash -> wsl.exe 時會被吃掉，於是 `C:\...` 抵達 wslpath 時變成 `C:Users...`，
# 轉換結果靜默地成為空字串。2026-10-22 實測。每個 wsl.exe 呼叫都需要
# MSYS2_ARG_CONV_EXCL。
W=$(MSYS2_ARG_CONV_EXCL='*' wsl.exe -- wslpath -u "$(cygpath -m "$TMP")" | tr -d '\r')

MSYS2_ARG_CONV_EXCL='*' wsl.exe -- bash -c "set -e
  # 1. order: a dangling LX link between two plain files
  mkdir -p '$W/order'; cd '$W/order'
  printf 'A\n' > aaa.txt; printf 'Z\n' > zzz.txt; ln -s nowhere mmm
  # 2. dir: an LX link to a directory
  mkdir -p '$W/dir'; cd '$W/dir'
  ln -s realdir dlink; mkdir realdir; printf 'inside\n' > realdir/f.txt
  # 3. deep: the same, with a subdirectory and links inside the subtree
  mkdir -p '$W/deep'; cd '$W/deep'
  ln -s tree dlink; mkdir -p tree/sub
  printf 'top\n' > tree/top.txt; printf 'deep\n' > tree/sub/deep.txt
  ln -s top.txt tree/inner; ln -s nowhere tree/dangle
  # 4. cycle: an LX link pointing back up its own path
  mkdir -p '$W/cycle/d'; cd '$W/cycle/d'; ln -s .. up"

# NOTE the LX links must be created by WSL; creating them from Git Bash gives a
# native IO_REPARSE_TAG_SYMLINK, which NT traverses happily and which therefore
# reproduces nothing. 注意 LX 連結必須由 WSL 建立；在 Git Bash 下建立會得到原生的
# IO_REPARSE_TAG_SYMLINK，NT 穿得過去，於是什麼也重現不出來。

for case in order dir deep cycle; do
  printf '######## %s ########\n' "$case"
  for impl in gnu bsd swift; do
    case $impl in
      gnu)   bin=/usr/bin/tar ;;
      bsd)   bin=/c/Windows/System32/tar.exe ;;
      swift) bin=$PWD/release/swift_tar.exe ;;
    esac
    rc=0
    ( cd "$TMP/$case" && "$bin" -c -h -f "$TMP/$case.$impl.tar" . ) \
      > "$TMP/$case.$impl.err" 2>&1 || rc=$?
    printf '  %-6s rc=%-3s members: ' "$impl" "$rc"
    release/swift_tar.exe -tf "$TMP/$case.$impl.tar" 2>/dev/null | tr '\n' ' '
    printf '\n'
    sed 's/^/           ! /' "$TMP/$case.$impl.err"
  done
done
```

## Measured results

### 1. `order` — the finding

A dangling LX link `mmm` sitting between `aaa.txt` and `zzz.txt`:

一個斷掉的 LX 連結 `mmm`，位於 `aaa.txt` 與 `zzz.txt` 之間：

| | rc | members | stderr |
|---|---|---|---|
| GNU tar | 1 | `./` `./aaa.txt` `./zzz.txt` | `./mmm: File removed before we read it` |
| **bsdtar** | **1** | **`./` `./aaa.txt`** | `./mmm: Cannot stat: Invalid argument` + `Error exit delayed from previous errors` |
| swift_tar | 0 | `./` `./aaa.txt` `./zzz.txt` | `skipping './mmm': --dereference cannot follow it` |

**`zzz.txt` is gone.** `aaa.txt`, which sorts before the bad entry, is present;
everything after it is not. The loss is therefore a function of directory order,
which is why it can hide: move the bad link to the end of the directory and the
archive looks complete.

**`zzz.txt` 不見了。** 排序在壞項目之前的 `aaa.txt` 在，之後的都不在。遺失的範圍取決於目錄
順序，這也是它能藏起來的原因：把壞連結移到目錄最後，封存看起來就是完整的。

`Error exit delayed from previous errors` is the part that makes this a trap rather
than a limitation. The phrase means "I finished the job and am now reporting the
earlier failure", and that is a reasonable thing for a caller to rely on. It is not
what happened.

讓這件事從「限制」變成「陷阱」的是 `Error exit delayed from previous errors` 這句。它的意思
是「我做完了，現在才回報先前的失敗」，而呼叫者依賴這個語意是合理的。但實際發生的並非如此。

### 2. `dir` — an LX link to a directory

| | rc | members |
|---|---|---|
| GNU tar | 0 | `./` `./dlink/` `./dlink/f.txt` `./realdir/` `./realdir/f.txt` |
| bsdtar | 1 | `./` |
| swift_tar | 0 | `./` `./dlink/` `./dlink/f.txt` `./realdir/` `./realdir/f.txt` |

bsdtar loses `realdir/` too — the link was the first entry, so the walk stopped
before reaching it. GNU tar resolves the link itself and stores the content read
from `realdir` under the link's name; `swift_tar` matches it member for member.

bsdtar 連 `realdir/` 也一併遺失——該連結是第一個項目，走訪在抵達 `realdir/` 之前就停了。
GNU tar 自行解析該連結，把從 `realdir` 讀到的內容存在連結的名稱之下；`swift_tar` 與它
逐一成員相同。

### 3. `deep` — links inside the resolved subtree

| | rc | members |
|---|---|---|
| GNU tar | 1 | 11, skipping `./dlink/dangle` and `./tree/dangle` |
| bsdtar | 1 | `./` |
| swift_tar | 0 | the same 11, skipping the same two |

### 4. `cycle` — an LX link pointing back up its own path

`cycle/d/up -> ..`

| | rc | members |
|---|---|---|
| **GNU tar** | **2** | **2,200+**: `./d/up/d/up/d/up/…` until `Cannot stat: Bad address`, then `Exiting with failure status due to previous errors` |
| bsdtar | **0** | `./` `./d/` `./d/up` — stored without following, and **exit 0** |
| swift_tar | 0 | `./` `./d/` + `skipping './d/up': --dereference would loop here` |

Two more findings, each the opposite of the implementation's behaviour elsewhere:

- **GNU tar does not detect this cycle.** Its `-h` cycle detection does not fire on
  an LX link, so it expands the path until the filesystem refuses it and leaves a
  2,200-member archive of nested garbage.
- **bsdtar exits 0 here**, on a link it cannot `stat` any more than the ones it
  exited 1 for in cases 1–3. So its exit code does not distinguish the two.

兩個額外發現，各自與該實作在別處的行為相反：

- **GNU tar 偵測不到這個迴圈。** 它的 `-h` 迴圈偵測對 LX 連結不生效，於是它把路徑一路展開到
  檔案系統拒絕為止，留下一個 2,200 個成員的巢狀垃圾封存。
- **bsdtar 在這裡退出 0**，而這個連結它 `stat` 不到的程度與案例 1–3 中讓它退出 1 的那些
  並無差別。也就是說它的退出碼無法區分這兩種情況。

## Why this matters

The combination in case 1 is the dangerous one: **non-zero exit *and* silent
partial output.** This repo's own README gives the correct response to a non-zero
exit from a create — treat the output as undefined, delete it, start over. That
advice is right, and here it does not help, because the retry produces the same
truncated archive. Nothing in the output or the exit code says how much is missing.

案例 1 的組合才是危險的那一個：**非零退出碼*加上*靜默的部分輸出。** 本 repo 的 README 對
「建立作業以非零結束」給出的正確反應是——視輸出為未定義、刪掉、重跑。那個建議是對的，而在
此處幫不上忙，因為重跑會得到同一個被截斷的封存。輸出與退出碼都不會說少了多少。

The exposure needs no unusual setup — a WSL `ln -s` anywhere in the tree, and the
`tar.exe` that is already on every Windows 11 machine.

這個暴露面不需要任何特殊設定——樹裡任何一處的 WSL `ln -s`，加上每台 Windows 11 上本來就有的
`tar.exe`。

## Why this mattered here

On 2026-10-22 a review asked whether `swift_tar -c` should exit non-zero when it
reports a skipped member, as GNU tar does for a dangling link. The first answer
given was that GNU tar's default is non-zero and `swift_tar` therefore diverges
from it — reasoning from one reference implementation.

2026-10-22 的一次審查問到：`swift_tar -c` 在回報略過成員時是否該以非零結束，一如 GNU tar
對斷鏈的處理。最初的回答是「GNU tar 的預設就是非零，故 `swift_tar` 與之分歧」——那是只依據
一個參照實作的推理。

Measuring the second one inverted the argument:

量了第二個之後，論點反轉：

- bsdtar returns non-zero on cases 1–3 and is **the implementation that loses the
  most data** in all three. Non-zero is not evidence of care.
- GNU tar itself exits **0** on case 2 — the case where a whole subtree is at
  stake — so there is no consistent reference default to converge on.
- The two disagree on the exit code for every fixture here except case 1.

so `swift_tar`'s documented behaviour — report the skip on stderr, archive
everything else, exit 0 on create — was **kept**, and the real defect the review
had found was a different one: on Windows, `-h` was dropping the entire subtree
under an LX link (case 2, 3 members instead of 5). That was fixed the same day;
the exit code was not changed.

因此 `swift_tar` 既有的文件化行為——把略過回報到 stderr、其餘全部封存、建立作業以 0 結束
——被**保留**；而該次審查真正找到的缺陷是另一個：在 Windows 上，`-h` 會丟掉 LX 連結底下的
整棵子樹（案例 2，3 個成員而非 5 個）。那個在同日修好，退出碼未變。

The lesson worth keeping is the method, not the verdict: **"the reference
implementation does X" is not a fact until more than one of them has been
measured.** Here the second measurement did not refine the first, it reversed it.

值得留下的是方法而非結論：**「參照實作是這樣做的」在只量過一個之前還不算事實。** 在此處，
第二次量測並非補強第一次，而是推翻了它。

## Scope of the measurement

**Windows only, one bsdtar build.** Everything above is `bsdtar 3.8.9` as shipped in
`C:\Windows\System32\tar.exe`, meeting reparse points NT refuses to traverse. No
claim is made about bsdtar on macOS or Linux, where LX reparse points do not exist
and the `stat` failure that starts the sequence therefore cannot occur in this form.
Whether the same walk-abort shows up there for a different unstattable entry — a
file deleted mid-walk, a permission-denied directory — is **not yet measured**.

**僅限 Windows，僅一個 bsdtar 版本。** 以上全部是 `C:\Windows\System32\tar.exe` 所附的
`bsdtar 3.8.9`，遇上 NT 拒絕穿越的 reparse point。對 macOS 或 Linux 上的 bsdtar 不作任何
主張——那些平台沒有 LX reparse point，故引發整串行為的 `stat` 失敗無法以此形式發生。同樣的
走訪中止是否會在那裡因別種 stat 不到的項目出現（走訪途中被刪的檔案、權限不足的目錄），
**尚未量測**。

## Not reported upstream

Neither finding has been filed with libarchive or GNU tar as of 2026-10-22. Both
are reproducible with the script above if someone wants to.

截至 2026-10-22，兩個發現均未向 libarchive 或 GNU tar 提報。若有人要提報，以上腳本可重現。
