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
- **Does not reproduce on macOS 27.2 with `bsdtar 3.5.3`** — see
  [Scope](#scope-macos-does-not-reproduce-it)

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

## Scope: macOS does not reproduce it

**The walk-abort is specific to the Windows build.** Measured on macOS 27.2 / APFS,
`bsdtar 3.5.3 - libarchive 3.7.4` (`/usr/bin/bsdtar`; `/usr/bin/tar` is the same
binary, confirmed by `cmp`), against `gtar 1.35` from Homebrew. LX reparse points do
not exist there, so the trigger had to be a different unstattable entry.

**走訪中止是 Windows 版本特有的。** 於 macOS 27.2／APFS 量測，`bsdtar 3.5.3 -
libarchive 3.7.4`（`/usr/bin/bsdtar`；`/usr/bin/tar` 為同一個執行檔，以 `cmp` 確認），
對照 Homebrew 的 `gtar 1.35`。那裡沒有 LX reparse point，故觸發條件必須換成別種 stat
不到的項目。

**The order caveat makes this stronger, not weaker.** APFS `readdir` order is not
alphabetical — `ls -f` gave `mmm ccc ddd eee bbb ggg aaa fff` — and both tars walk in
`readdir` order, so the bad entry came **first** and every sibling came after it. That
is the worst case for the defect, and it still did not appear.

**順序這個附帶條件讓結論更強而非更弱。** APFS 的 `readdir` 順序並非字典序——`ls -f` 得到
`mmm ccc ddd eee bbb ggg aaa fff`——而兩個 tar 都依 `readdir` 順序走訪，故壞項目排在
**第一個**，所有兄弟項目都在它之後。那是這個缺陷最壞的情況，而它仍未出現。

### macOS, `chmod 000` directory `mmm/` between `aaa.txt` and `zzz.txt`

| | rc | members |
|---|---|---|
| bsdtar 3.5.3 | 1 | `./` `./mmm/` `./aaa.txt` `./zzz.txt` — **`zzz.txt` survives** |
| gtar 1.35 | 2 | `./` `./aaa.txt` `./zzz.txt` (`./mmm` dropped entirely) |

bsdtar's stderr: `Couldn't list extended attributes: Permission denied`, `./mmm:
Couldn't visit directory: Permission denied`, `Error exit delayed from previous
errors.` — and here the phrase is accurate. Without `-h`, and via `/usr/bin/tar`,
identical.

### macOS, an unfollowable symlink under `-h`

Two fixtures, 7 sibling files each: `mmm -> nowhere` (dangling, `lstat` works), and
`mmm -> ../locked/f.txt` where `locked` is `chmod 000` (`stat` gives `EACCES`).

| | rc | what happens to `mmm` |
|---|---|---|
| bsdtar 3.5.3 `-h` | **0** | **stored as a symlink** (`lrwx ./mmm -> nowhere`), silently |
| gtar 1.35 `-h` | 1 / 2 | dropped, reported |
| swift_tar `-h` | 0 | skipped, reported — **changed later the same day**, see below |

All 7 siblings survive in every case. A third behaviour worth recording: **bsdtar's
`-h` falls back to `lstat` and stores the link itself, with no message and exit 0.**
`-h` asked it to dereference; it archived a symlink entry instead and said nothing.
That is not data loss, but an archive built with `-h` is documented to contain no
symlink entries at all, and a caller relying on that gets one anyway.

> **The swift_tar row above is the pre-fix behaviour.** Later on 2026-10-22 the two
> `--dereference cannot follow it` sites were changed to store the link itself as
> bsdtar does, so the member is no longer dropped; unlike bsdtar it still reports
> what it did. The entry in that row is now `stored as a link, reported`, exit 0.
> bsdtar's measurement here is what prompted the change: dropping a member to signal
> "I could not dereference this" loses more than it communicates. bsdtar's own
> silence was not copied.
>
> **上表 swift_tar 那一列是修正前的行為。** 2026-10-22 當日稍後，兩處
> `--dereference cannot follow it` 已改為比照 bsdtar 存下連結本身，成員不再被丟掉；與
> bsdtar 不同的是它仍會回報自己做了什麼。該列現在應為「存成連結、有回報」、退出 0。
> 促成這項改動的正是此處對 bsdtar 的量測：用「丟掉一個成員」來表示「我無法解參照」，
> 失去的比傳達的多。但 bsdtar 的沉默沒有一併照抄。

全部 7 個兄弟項目在每一種情況下都存活。第三個值得記下的行為：**bsdtar 的 `-h` 會退回
`lstat` 並存下連結本身，沒有任何訊息、退出 0。** `-h` 要求它解參照，它卻存了一個 symlink
項目而且不作聲。這不是資料遺失，但以 `-h` 建立的封存按文件是完全不含 symlink 項目的，
依賴這一點的呼叫者會拿到一個。

### Still not measured

- bsdtar on Linux.
- A file **deleted mid-walk**, on any platform.
- Whether the Windows walk-abort comes from the 3.8.9 build or from LX handling
  specifically. The macOS run cannot separate those two, because it has neither.

### The Windows equivalent of the macOS fixture fails differently

For completeness: the `chmod 000` directory has no Windows analogue, because Windows
does not enforce POSIX mode bits against the owner. Denying the directory with an ACL
instead (`icacls mmm /deny <user>:(RD)`) blocks `winStat` as well as the listing, so
`swift_tar` throws `cannot stat './mmm'` and the create aborts at **rc 1 with
`./ ./aaa.txt`** — `zzz.txt` lost. That is this tool's documented create-failure
behaviour (see [Exit status](../README.md#exit-status): a failed create leaves a valid
archive holding the entries processed before it) and not the same defect, but it does
mean the macOS fixture cannot be replayed on Windows as written.

為完整起見：`chmod 000` 目錄在 Windows 上沒有對應物，因為 Windows 不對擁有者強制 POSIX
mode 位元。改以 ACL 拒絕該目錄（`icacls mmm /deny <user>:(RD)`）會同時擋住 `winStat` 與
列目錄，於是 `swift_tar` 擲出 `cannot stat './mmm'`，建立作業以 **rc 1、`./ ./aaa.txt`**
中止——`zzz.txt` 遺失。那是本工具已文件化的建立失敗行為（見
[Exit status](../README.md#exit-status)：失敗的建立會留下一個含先前已處理項目的有效封存），
並非同一個缺陷，但它表示 macOS 那組測資無法照原樣在 Windows 上重播。

## Not reported upstream

Neither finding has been filed with libarchive or GNU tar as of 2026-10-22. Both
are reproducible with the script above if someone wants to.

截至 2026-10-22，兩個發現均未向 libarchive 或 GNU tar 提報。若有人要提報，以上腳本可重現。
