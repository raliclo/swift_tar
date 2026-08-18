# Cross-platform verification flow / 跨平台驗證流程

Two machines work on this repository at once — macOS here, Windows there — and
both have run blind documentation tests and fixed defects independently. Twice
now that has produced avoidable damage: a fix verified only on Windows took ZIP
out entirely on macOS, and a rebase of parallel README edits nearly duplicated
two whole sections. This file exists so the order of operations is written down
rather than re-derived each time.

本程式庫同時有兩台機器在作業——此處是 macOS，另一端是 Windows——雙方都各自跑過盲測
並修過缺陷。至今已有兩次因此造成本可避免的損害：一個僅在 Windows 驗證過的修正讓
macOS 的 ZIP 完全失效；而平行的 README 編輯在 rebase 時幾乎複製了整整兩個章節。本檔
的存在，是為了把操作順序寫下來，而不是每次重新推導。

## The rule / 規則

**Gather every platform's evidence first. Change the code once, at the end.**

**先收齊所有平台的證據，最後才一次改完程式碼。**

Not because batching is tidier, but because a change made after seeing one
platform is a change made in ignorance of the other three. The ZIP outage is the
worked example: `hdrcharset=UTF-8` was correct for Windows, fatal for macOS, and
nobody could have known that from the Windows machine alone.

這麼做不是因為批次比較整齊，而是因為「只看過一個平台就動手」等於在對其餘三個平台
一無所知的情況下修改。ZIP 停擺就是現成的例子：`hdrcharset=UTF-8` 對 Windows 是正確的、
對 macOS 是致命的，而單憑 Windows 那台機器不可能得知這件事。

## The four phases / 四個階段

### Phase 1 — build and measure, in parallel, changing nothing
### 階段一 — 平行建置與量測，不改任何東西

On each platform: build, then run the suites. Record the results. **Do not fix
anything yet**, however obvious the fix looks — that is the phase whose whole
purpose is to be ignorant of the answer.

| Platform | Build | Interop matrix | Reference tars expected |
|---|---|---|---|
| macOS | `./build.zsh` | `verifications/tar_interop_matrix.zsh` | bsdtar (`/usr/bin/tar`), GNU tar (`gtar`, from `brew install gnu-tar`) |
| Windows / MSYS | `./build.zsh` | same | bsdtar (`C:\Windows\System32\tar.exe`), GNU tar (MSYS `tar`) |
| WSL | via multissh | same | GNU tar; bsdtar only if installed |
| Linux VM on macOS | `~/projWin/VM-test/run.sh` | **not a matrix platform — see below** | — |

**The Linux VM is deliberately not an interop reference platform.** Its
buildroot config leaves `BR2_PACKAGE_TAR` unset on purpose, so `tar` there is
the busybox applet and there is no GNU tar. Do not add the package and do not
go looking for reference tars in the guest: the VM exists to prove swift_tar
*builds and runs* on Linux, and interop against GNU tar and bsdtar is covered on
macOS, Windows and WSL, where those tools are the ones users actually have.

**Linux VM 刻意不作為互通參照平台。** 其 buildroot 設定刻意不設
`BR2_PACKAGE_TAR`，故該處的 `tar` 是 busybox applet，且沒有 GNU tar。請不要加入該
套件，也不要在 guest 內尋找參照 tar：這台 VM 的用途是證明 swift_tar 在 Linux 上
**建置得起來、跑得動**；與 GNU tar 及 bsdtar 的互通由 macOS、Windows 與 WSL 覆蓋，
那裡的這些工具才是使用者手上實際會有的。

> **Trap, if anyone does probe that guest anyway:** `/usr/bin/tar` in it is
> **swift_tar itself**, installed under that name — it reports
> `swift_tar 20260813-080906`, while busybox tar sits at `/bin/tar` and bsdtar
> 3.8.8 at `/usr/bin/bsdtar`. A matrix that picked its reference by filename
> would have compared swift_tar against itself and reported flawless interop.
> This is the concrete reason the matrix identifies every candidate by what it
> says about itself and rejects anything that is neither bsdtar nor GNU tar.
> **若仍有人去探測該 guest，這是陷阱：** 其 `/usr/bin/tar` **就是 swift_tar 自己**，
> 以該名稱安裝，自報為 `swift_tar 20260813-080906`；busybox tar 在 `/bin/tar`，
> bsdtar 3.8.8 在 `/usr/bin/bsdtar`。以檔名挑選參照工具的矩陣，會拿 swift_tar 與
> 自己比對並回報完美互通。這正是矩陣以自我描述辨識每個候選者、並拒絕任何既非
> bsdtar 亦非 GNU tar 之物的具體理由。

### Consequences of the VM's tar, for anything that runs there
### VM 的 tar 對在該處執行之物的影響

Two properties follow from that decision, and both are intended:

**busybox tar cannot compress.** `tar -czf` in the guest fails with
`tar: invalid option -- 'z'`, and so does `-tzf` on read. Use `/usr/bin/bsdtar`
for anything compressed. This is not a gap to fix — it is why bsdtar is in the
image at all.

**`tar` in the guest is swift_tar.** Any test that wants a *foreign* archive
must not reach for `tar` by name there, or it will encrypt, extract or compare
swift_tar's own output and call it third-party. `test_encrypt.zsh` picks its
`.tgz` producer by self-description for exactly this reason: it skips anything
reporting `swift_tar`, skips busybox because it cannot compress, and reports a
clean SKIP if no compressing third-party tar exists rather than failing on a
precondition the platform was never meant to meet.

該決定帶來兩個後果，兩者皆為預期：

**busybox tar 不能壓縮。** guest 內的 `tar -czf` 會以
`tar: invalid option -- 'z'` 失敗，讀取端的 `-tzf` 亦然。需要壓縮時請用
`/usr/bin/bsdtar`。這不是待補的缺口——bsdtar 之所以在映像中，正是為此。

**guest 內的 `tar` 是 swift_tar。** 任何需要「外來封存」的測試都不可在該處以名稱取用
`tar`，否則會把 swift_tar 自己的輸出拿去加密、解出或比對，並稱之為第三方。
`test_encrypt.zsh` 挑選 `.tgz` 產生器時以自我描述為準，正是為此：略過自報 `swift_tar`
者、略過不能壓縮的 busybox，若不存在可壓縮的第三方 tar 則乾淨跳過並回報，而不是在一個
該平台本就不預期滿足的前提上失敗。

What the VM *is* for still has one thing worth checking when it is next built:
its rootfs is UTF-8 only and its buildroot config states plainly
`# UTF-8-only rootfs: do not pull in libiconv`. libarchive without iconv is
exactly the configuration that made `hdrcharset=UTF-8` fail on macOS and took
every ZIP write with it, so `--zip` in the guest exercises the same path the
macOS fix was written for. If ZIP works there, that fix is confirmed on a second
platform that reached the condition independently.

該 VM 真正的用途裡，仍有一件事值得在下次建置時檢查：其 rootfs 僅支援 UTF-8，
buildroot 設定明白寫著 `# UTF-8-only rootfs: do not pull in libiconv`。
「libarchive 不含 iconv」正是使 `hdrcharset=UTF-8` 在 macOS 失敗、並連帶讓所有 ZIP
寫入一起停擺的那個組態，故在 guest 內執行 `--zip` 會走上 macOS 修正所針對的同一條
路徑。若該處 ZIP 可用，即等於在一個獨立達到相同條件的第二平台上確認了該修正。

The matrix identifies each reference by what it says about itself, never by
filename: `tar` is bsdtar on macOS, GNU tar on most Linux, and on Windows
`tar.exe` is bsdtar while the MSYS `tar` is GNU. Keying on filenames mislabels
every row.

矩陣以各參照工具的自我描述辨識，絕不以檔名判斷：`tar` 在 macOS 是 bsdtar、在多數
Linux 是 GNU tar，而 Windows 的 `tar.exe` 是 bsdtar、MSYS 的 `tar` 則是 GNU。
以檔名為鍵會把每一列都標錯。

Parallelism is real but bounded: background agents and background builds run
concurrently, and independent tool calls in one message run concurrently. What
cannot overlap is two lines of work editing the same tree.

可平行的部分是真的，但有界線：背景 agent、背景建置、以及單一訊息內的獨立呼叫都能
並發。無法重疊的是「兩條線編輯同一個工作樹」。

### Phase 2 — consolidate the requirements before writing anything
### 階段二 — 動手之前，先彙整需求

Put every platform's failures in one place and ask of each: is this a defect, or
is it that platform's convention? The two are fixed differently and the answer is
rarely visible from one machine.

Worked example, from this repository: the matrix first reported "swift_tar
cannot read bsdtar's archives" on macOS. It was not a defect. macOS bsdtar writes
an AppleDouble `._name` member beside every entry to carry extended attributes,
hides them again on its own read, and folds them back into xattrs. GNU tar lists
them, extracts them as ordinary files, and warns about the unknown header — and
swift_tar does exactly what GNU tar does. The finding was real; the diagnosis
"swift_tar is broken" was wrong. Confirmed by reading the raw tar headers, with
no tar involved at all.

把各平台的失敗集中起來，逐項自問：這是缺陷，還是該平台的慣例？兩者的修法不同，而
答案很少能從單一機器看出來。

實例：矩陣起初在 macOS 回報「swift_tar 讀不懂 bsdtar 的封存」。那不是缺陷。macOS 的
bsdtar 會為每個項目寫入 AppleDouble `._名稱` 成員以攜帶延伸屬性，並在自己讀取時隱藏、
解出時還原為 xattr。GNU tar 會列出它們、解為一般檔案並警告該標頭無法辨識——而
swift_tar 的行為與 GNU tar 完全相同。發現本身是真的，「swift_tar 壞了」這個診斷是錯的。
最終以直接讀取原始 tar 標頭確認，全程不經任何 tar。

**When a platform disagrees with the others, name which one is the outlier
before deciding who is wrong.**
**當某個平台與其他不同時，先指出誰是離群者，再決定誰錯了。**

### Phase 3 — one change, addressing all platforms at once
### 階段三 — 一次改完，同時涵蓋所有平台

Write the fix knowing every platform's constraint. A fix that helps one platform
must be checked against the mechanism the others rely on — the ZIP fix kept
Windows's `hdrcharset` path untouched and added a second, separate mechanism for
the platforms where that option cannot work.

Also: a fix in one direction is not a fix. Setting the UTF-8 flag on write alone
produced archives that bsdtar and Python read correctly and swift_tar itself
could not open. Both directions, or neither.

在知悉所有平台限制的前提下寫出修正。對某一平台有幫助的修正，必須對照其他平台所依賴的
機制檢查——ZIP 的修正完整保留了 Windows 的 `hdrcharset` 路徑，另外為該選項無法運作的
平台加上第二套獨立機制。

另外：只修一個方向不算修好。只在寫入端設定 UTF-8 旗標，產出的封存 bsdtar 與 Python
讀得正確，swift_tar 自己卻打不開。要嘛兩個方向都做，要嘛都不做。

### Phase 4 — re-verify everywhere, then record
### 階段四 — 各平台重新驗證，然後才記錄

Re-run Phase 1 on every platform against the changed build. Only a fully passing
run may write a record — `--record` is opt-in on the scripts that write to
`verifications/`, because a correctness run that silently overwrites a
measurement leaves a record nobody chose to take.

以更動後的建置在每個平台重跑階段一。唯有全數通過的執行才可寫入紀錄——會寫入
`verifications/` 的腳本一律以 `--record` 選擇性加入，因為一次靜默覆寫量測的正確性執行，
留下的是一份沒有人決定過要取得的紀錄。

## Where things are recorded / 各類事項記錄於何處

| Kind | Goes in |
|---|---|
| How to use a feature | `README.md` + `README.zh-TW.md`, both, kept symmetric |
| A defect, or an incompatibility with another tool | `todo/todo.md` — **not** the README |
| A measurement | `verifications/*_output-<platform>.txt`, written only with `--record` |
| A regression test for a fixed defect | `test_blind_findings.zsh` |

Defect narratives were moved out of the READMEs deliberately: a README that
catalogues its own bugs teaches the reader to distrust the parts that are fine.

缺陷敘述是刻意移出 README 的：一份羅列自身缺陷的 README，會教讀者連正確的部分也不要
相信。

## Standing rules that keep biting / 一再重演、故列為常規

- **Verify the agent, not just the code.** A blind tester has been wrong about
  its own findings four times in seven rounds — "input is stdin only" (a
  positional path works), "`-f` has two directions" (it has three), "there is no
  timezone flag" (`--tz-offset-min`), "480 may be the host timezone" (it is a
  constant). Every one would have gone into the README verbatim.
  **驗證的對象包含 agent，不只是程式碼。** 盲測者在七回合中有四次對自己的發現判斷
  錯誤，每一項若照抄都會逐字寫進 README。
- **A test that cannot fail proves nothing.** Run the new test against the
  unfixed binary before believing it.
  **不會失敗的測試什麼也證明不了。** 相信一個新測試之前，先拿未修正的執行檔跑一次。
- **`.sh` → `.zsh` renames drop the exec bit.** Eleven committed scripts became
  non-executable that way; two test suites failed with 126 as a result.
  **`.sh` → `.zsh` 改名會掉執行位元。** 曾有十一支入版腳本因此無法執行。
- **Check `git status` after a suite run.** Scripts that write records will
  otherwise commit a measurement taken under machine load — one such table came
  in with every time uniformly 8% slower and the sizes unchanged.
  **跑完測試後檢查 `git status`。** 否則會把機器負載下取得的量測提交進去。
