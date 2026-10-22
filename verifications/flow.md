# Cross-platform verification flow / 跨平台驗證流程

Several machines work on this repository at once, and each can run blind
documentation tests and fix defects independently. A fix verified on one platform
can break another, and parallel README edits can collide on rebase. This file
writes down the order of operations so it is not re-derived each time.

本程式庫同時有多台機器在作業，每一台都可能各自跑盲測並修缺陷。只在一個平台驗證過的
修正可能弄壞另一個平台，平行的 README 編輯也可能在 rebase 時互相衝突。本檔把操作順序
寫下來，而不是每次重新推導。

## The rule / 規則

**Gather every platform's evidence first. Change the code once, at the end.**

**先收齊所有平台的證據，最後才一次改完程式碼。**

Not because batching is tidier, but because a change made after seeing one
platform is a change made in ignorance of the other three. For example, ZIP's
`hdrcharset=UTF-8` works on Windows and breaks every ZIP write on macOS, and
nothing on the Windows machine alone shows that.

這麼做不是因為批次比較整齊，而是因為「只看過一個平台就動手」等於在對其餘三個平台
一無所知的情況下修改。例如 ZIP 的 `hdrcharset=UTF-8` 在 Windows 上可行，在 macOS 上
卻會讓所有 ZIP 寫入失敗，而單憑 Windows 那台機器看不出這件事。

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
| WSL | via multissh | same | GNU tar 1.35; **no bsdtar installed** |
| Linux VM on macOS | `~/projWin/VM-test/run.sh` | **not a matrix platform — see below** | — |

**WSL cell, run from macOS on 2026-09-05: PASS 6 / FAIL 0 / SKIP 0.**
The run wrote 1036 bytes and 25 lines on the far side; the file was fetched with
`multiscp` and its sha256 compared, matching end to end
(`f25015e41be3afe6d43ff75284dec0cafcb43ae03918876cbab4c17dd66bc467`).

macOS reaches WSL directly over `multissh`; there is no need to drive it from the
Windows box. If a read on the far side fails with
`Input/output error (os error 5)` after the connection and shell came up, WSL's
filesystem is wedged — not the transport, which would fail at connect.
`wsl --shutdown` and a restart clear it.

### How to record this cell / 如何記錄這一格

Never take a cell from an exit status. Have the far side write its output to a
file, report the size and digest **there**, fetch the file, and compare the
digest **here**:

```zsh
C=~/.multissh/harvest/wsl.conf          # 16889 is WSL; 16888 on the same address is Windows
./release/multissh -F "$C" wslnode '
  cd ~/proj/multissh/swift_tar || exit 9
  zsh verifications/tar_interop_matrix.zsh > /tmp/wsl-matrix.txt 2>&1
  echo "MATRIX_RC=$?"
  echo "BYTES=$(wc -c < /tmp/wsl-matrix.txt)"
  echo "SHA=$(sha256sum /tmp/wsl-matrix.txt | cut -d" " -f1)"'
./release/multiscp -F "$C" wslnode:/tmp/wsl-matrix.txt ./wsl-matrix.txt
shasum -a 256 ./wsl-matrix.txt          # must equal the SHA printed above
```

`BYTES` is part of the check: a run that exits 0 having written zero bytes has
to be treated as a failure, because zero bytes and
"passed quietly" are the same picture. If output really is failing, this reports
it as a wedged far side rather than as a passing matrix.

Confirm which daemon answered before trusting a result. Mirrored networking puts
WSL and Windows on one address, separated only by port, so reachability alone
proves nothing — `uname -s` must say `Linux`.

**WSL 那一格，2026-09-05 自 macOS 執行：PASS 6 / FAIL 0 / SKIP 0。** 該次在遠端
寫出 1036 位元組、25 行，再以 `multiscp` 取回並比對 sha256，兩端完全相同
（`f25015e41be3afe6d43ff75284dec0cafcb43ae03918876cbab4c17dd66bc467`）。

macOS 經由 `multissh` 直接搆得到 WSL，不需要改到那台 Windows 上驅動。若連線與 shell
都已建立、之後讀取卻遇到 `Input/output error (os error 5)`，是 WSL 的檔案系統卡住了，
不是傳輸層——傳輸層壞了會在連線階段就失敗。`wsl --shutdown` 後重啟即可排除。

記錄方式見上方程式碼區塊：**絕不以離開碼記錄一格**。讓對端把輸出寫進檔案、在**那一端**
回報大小與摘要，取回檔案後在**這一端**比對摘要。`BYTES` 是檢查的一部分——以 0
結束卻寫出零位元組的執行必須當成失敗，因為「零位元組」與「安靜地通過」在畫面上是同一
幅景象。輸出若真的壞了，這個做法會把它報成「對端卡住」，而不是報成一次通過的矩陣。

信任結果之前先確認回應的是哪一個 daemon。鏡像網路讓 WSL 與 Windows 共用同一位址、僅以
埠區分，因此「連得上」什麼都不證明——`uname -s` 必須回 `Linux`。

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
> **swift_tar itself**, installed under that name — its `--version` reports
> `swift_tar`, while busybox tar sits at `/bin/tar` and bsdtar 3.8.8 at
> `/usr/bin/bsdtar`. A matrix that picked its reference by filename would
> compare swift_tar against itself and report flawless interop.
> This is the concrete reason the matrix identifies every candidate by what it
> says about itself and rejects anything that is neither bsdtar nor GNU tar.
> **若仍有人去探測該 guest，這是陷阱：** 其 `/usr/bin/tar` **就是 swift_tar 自己**，
> 以該名稱安裝，`--version` 自報為 `swift_tar`；busybox tar 在 `/bin/tar`，
> bsdtar 3.8.8 在 `/usr/bin/bsdtar`。以檔名挑選參照工具的矩陣，會拿 swift_tar 與
> 自己比對並回報完美互通。這正是矩陣以自我描述辨識每個候選者、並拒絕任何既非
> bsdtar 亦非 GNU tar 之物的具體理由。

### Running something in the VM / 在 VM 內執行東西

`~/projWin/VM-test/run.sh 'command'` boots, runs one command, powers off. Three
things about it are worth knowing before writing that command:

**It boots into a root shell.** `run.sh` passes `init=/bin/sh` and does the
setup inline: the three pseudo-filesystems, `/workspace` from `/dev/vdb`, and
the Swift environment. That setup matches the first half of LinuxCS's
`/init-server`. The second half of that file — building and starting
`multisshd` — is deliberately not reproduced, and it also never spawns a
console shell, so it cannot be reused as-is by a harness that
works by typing a command at one.

Root is not a convenience here. Everything under `/workspace` is owned by
`501:20`, the macOS build user: buildroot cannot fakeroot on macOS, so the
chown, permissions-table and mknod steps are stripped from the generated script
(LinuxCS's `fix_image_ownership.zsh` exists for exactly this). The guest's `dev`
is uid 100, so as `dev` the workspace is readable and entirely unwritable, and
sudo does not help — this rootfs grants `dev` one sudo command, `poweroff`.

**`/tmp` is tmpfs and every invocation is a fresh boot.** Anything built there
is gone by the next call. Build under `/workspace`, which persists — the point
of doing so is that the next run can reuse the result instead of rebuilding.

**A previous build is usually already there.** LinuxCS's convention puts the
source at `/workspace/multissh/swift_tar` and the binary at its `release/`.
Check that before building anything: it may be current enough for what you need,
and the only way to know is to compare its `--version` against the change you
are trying to verify.

`~/projWin/VM-test/run.sh 'command'` 會開機、執行一道指令、關機。寫那道指令之前，
有三件事值得先知道：

**它會開機進入 root shell。** `run.sh` 傳入 `init=/bin/sh`，並在行內完成環境設定：
三個虛擬檔案系統、自 `/dev/vdb` 掛載 `/workspace`，以及 Swift 環境。這段設定與
LinuxCS 的 `/init-server` 前半段相同。該檔的後半段（建置並啟動
`multisshd`）刻意不予重現；而且它從不開啟主控台 shell，故無法被「靠輸入指令運作」的
測試框架原樣沿用。

此處的 root 並非圖方便。`/workspace` 底下所有檔案的擁有者是 `501:20`，即 macOS 的
建置使用者：buildroot 在 macOS 上無法 fakeroot，chown、權限表與 mknod 三個步驟會從
產生的腳本中被剝除（LinuxCS 的 `fix_image_ownership.zsh` 正是為此而存在）。guest 的
`dev` 是 uid 100，故以 `dev` 身分該 workspace 讀得到、完全寫不了，而 sudo 也幫不上忙
——本 rootfs 只授予 `dev` 一道 sudo 指令，即 `poweroff`。

**`/tmp` 是 tmpfs，且每次呼叫都是全新開機。** 建在那裡的東西下次呼叫就不見了。請建在
會持久保存的 `/workspace`——這麼做的意義正在於下次可以重用結果而不必重建。

**先前的建置多半已經在那裡。** LinuxCS 的慣例是原始碼放 `/workspace/multissh/swift_tar`、
執行檔放其 `release/`。動手建置前先看那裡：它可能已足夠新，而唯一的判斷方式是把它的
`--version` 與你想驗證的那項改動相比。

Performance in the guest — core count, the cost of running without
`-accel`, and why bsdtar wins on extraction while swift_tar wins on
compression — is measured in [`../FAQ.md`](../FAQ.md).
guest 內的效能——核心數、未啟用 `-accel` 的代價，以及為何解壓是 bsdtar 快而壓縮
是 swift_tar 快——的實測數字見 [`../FAQ.md`](../FAQ.md)。

### Consequences of the VM's tar, for anything that runs there
### VM 的 tar 對在該處執行之物的影響

Two properties follow from that decision, and both are intended:

**busybox tar cannot compress.** `tar -czf` in the guest fails with
`tar: invalid option -- 'z'`, and so does `-tzf` on read. Use `/usr/bin/bsdtar`
for anything compressed. This is not a gap to fix — it is why bsdtar is in the
image at all.

**`tar` in the guest is swift_tar.** Any test that wants a *foreign* archive
must not reach for `tar` by name there, or it will encrypt, extract or compare
swift_tar's own output and call it third-party. `test/test_encrypt.zsh` picks its
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
`test/test_encrypt.zsh` 挑選 `.tgz` 產生器時以自我描述為準，正是為此：略過自報 `swift_tar`
者、略過不能壓縮的 busybox，若不存在可壓縮的第三方 tar 則乾淨跳過並回報，而不是在一個
該平台本就不預期滿足的前提上失敗。

### ZIP on a second iconv-free platform
### 第二個無 iconv 平台上的 ZIP

Its rootfs is UTF-8 only and its buildroot config states plainly
`# UTF-8-only rootfs: do not pull in libiconv`. libarchive without iconv is
exactly the configuration in which `hdrcharset=UTF-8` fails on macOS and takes
every ZIP write with it — and this platform reaches that condition on its own,
independently of the macOS build.

Measured 2026-08-18 with `swift_tar 20260818-073727`, built in the guest:

```
--zip                          exit 0
swift_tar -t                   src/ · src/中文檔名.txt · src/a.txt
extract + diff -r              identical
bsdtar 3.8.8 -tf               the same three names, the non-ASCII one intact
```

So swift_tar's ZIP writing holds on a second platform that reaches the
iconv-free condition independently. One platform passing could mean the code
matches that platform's quirk; two means it matches the actual mechanism.

其 rootfs 僅支援 UTF-8，buildroot 設定明白寫著
`# UTF-8-only rootfs: do not pull in libiconv`。「libarchive 不含 iconv」正是使
`hdrcharset=UTF-8` 在 macOS 失敗、並連帶讓所有 ZIP 寫入一起失敗的那個組態——而本平台
是獨立地走到該條件，與 macOS 的建置無關。

2026-08-18 以 guest 內建置的 `swift_tar 20260818-073727` 實測，結果如上表。

故 swift_tar 的 ZIP 寫入在一個獨立達到「無 iconv」條件的第二平台上同樣成立。單一平台
通過，可能只代表程式剛好迎合了該平台的特性；兩個平台通過，才代表它命中的是真正的機制。

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

Example: on macOS, the matrix can report "swift_tar cannot read bsdtar's
archives". That is not a defect. macOS bsdtar writes an AppleDouble `._name`
member beside every entry to carry extended attributes, hides them again on its
own read, and folds them back into xattrs. GNU tar lists them, extracts them as
ordinary files, and warns about the unknown header — and swift_tar does exactly
what GNU tar does.

把各平台的失敗集中起來，逐項自問：這是缺陷，還是該平台的慣例？兩者的修法不同，而
答案很少能從單一機器看出來。

實例：在 macOS 上，矩陣可能回報「swift_tar 讀不懂 bsdtar 的封存」。那不是缺陷。
macOS 的 bsdtar 會為每個項目寫入 AppleDouble `._名稱` 成員以攜帶延伸屬性，並在自己讀取時
隱藏、解出時還原為 xattr。GNU tar 會列出它們、解為一般檔案並警告該標頭無法辨識——而
swift_tar 的行為與 GNU tar 完全相同。

**When a platform disagrees with the others, name which one is the outlier
before deciding who is wrong.**
**當某個平台與其他不同時，先指出誰是離群者，再決定誰錯了。**

### Phase 3 — one change, addressing all platforms at once
### 階段三 — 一次改完，同時涵蓋所有平台

Write the fix knowing every platform's constraint. A fix that helps one platform
must be checked against the mechanism the others rely on — swift_tar's ZIP name
handling keeps Windows's `hdrcharset` path and uses a second, separate mechanism
on the platforms where that option cannot work.

Also: a fix in one direction is not a fix. Setting the UTF-8 flag on write alone
produces archives that bsdtar and Python read correctly and swift_tar itself
cannot open. Both directions, or neither.

在知悉所有平台限制的前提下寫出修正。對某一平台有幫助的修正，必須對照其他平台所依賴的
機制檢查——swift_tar 的 ZIP 名稱處理保留 Windows 的 `hdrcharset` 路徑，並在該選項無法
運作的平台上使用第二套獨立機制。

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
| A regression test for a fixed defect | `test/test_blind_findings.zsh` |

Defect narratives stay out of the READMEs deliberately: a README that
catalogues its own bugs teaches the reader to distrust the parts that are fine.

缺陷敘述刻意不放在 README：一份羅列自身缺陷的 README，會教讀者連正確的部分也不要
相信。

## Standing rules that keep biting / 一再重演、故列為常規

- **Verify the agent, not just the code.** A blind tester can be wrong about
  its own findings — e.g. "input is stdin only" (a positional path works),
  "`-f` has two directions" (it has three), "there is no timezone flag"
  (`--tz-offset-min`), "480 may be the host timezone" (it is a constant). Copied
  as-is, each would go into the README verbatim.
  **驗證的對象包含 agent，不只是程式碼。** 盲測者對自己的發現也可能判斷錯誤，照抄就會
  逐字寫進 README。
- **A test that cannot fail proves nothing.** Run the new test against the
  unfixed binary before believing it.
  **不會失敗的測試什麼也證明不了。** 相信一個新測試之前，先拿未修正的執行檔跑一次。
- **A fallback inside a test can hide the case the test exists for.** In a case
  written as `cmd1 || cmd2`, if `cmd1` *succeeds* on one platform by taking the
  broken path, the fallback never runs and the case passes on exactly the
  behaviour it was meant to catch. If a case needs a fallback, assert which
  branch ran.
  **測試內部的備援，可能掩蓋該測試存在的目的。** 寫成 `cmd1 || cmd2` 的案例，若
  `cmd1` 在某個平台上走壞掉那條卻**成功**，備援永不執行，案例就在它本該抓到的行為上
  通過。若某案例確實需要備援，請斷言實際走的是哪一支。
- **A `SKIP` never becomes a `FAIL`, so nothing reports it.** A guard such as
  `if [ -f "$fixture" ]` with a wrong fixture path silently skips every
  assertion behind it while the suite still says `FAIL: 0`. Read the skip lines,
  and compare the assertion count against the last run.
  **`SKIP` 永遠不會變成 `FAIL`，因此無人回報。** 像 `if [ -f "$fixture" ]` 這樣的
  守門，若 fixture 路徑錯了，其後所有斷言都會靜默略過，而整體仍回報 `FAIL: 0`。請讀
  skip 行，並與上一次的斷言總數比對。
- **Confirm the phenomenon before profiling it.** A profiler always returns some
  hottest function, and that function then gets mistaken for the cause. The
  extract gap, for example, is real on Linux (1.24–1.46×) but not on macOS;
  profiling it on macOS would produce a confident mechanism for a gap that is
  not there.
  **先確認現象還在，再 profile。** profiler 一定會回報「某個最花時間的函式」，而那個
  函式接著就會被當成成因。例如解壓差距在 Linux 上是真的（1.24–1.46 倍），在 macOS 上
  則不是；在 macOS 上 profile，得到的會是一個為「並不存在的差距」寫下的、看起來很有
  把握的機制。
- **A short-lived target defeats sampling profilers, and the failure is silent.**
  Extracting a RAM-disk archive runs about 0.17 s. `sample <pid>` and
  `sample -wait` both returned **zero** samples; `xctrace --launch` returned 52;
  recording a 25-iteration loop returned 13, all attributed to the wrapper shell
  because `--launch` does not follow child processes. None of these reported an
  error — each produced an empty or near-empty profile that reads like a result.
  Check the sample count before reading a profile.
  **壽命短的目標會讓取樣式 profiler 失效，而且失敗是無聲的。** 解開 RAM disk 上的封存
  約 0.17 秒：`sample <pid>` 與 `sample -wait` 各取到 **0** 個樣本；`xctrace --launch`
  取到 52 個；錄一個 25 次的迴圈只得 13 個，且全部歸給外層 shell——`--launch` 不追子
  行程。這些都沒有報錯，各自產出一份空的或近乎空的 profile，讀起來就像一個結果。讀
  profile 之前先看樣本數。
- **`.sh` → `.zsh` renames can drop the exec bit**, and a suite that runs the
  script then fails with 126.
  **`.sh` → `.zsh` 改名可能掉執行位元**，執行該腳本的測試套件就會以 126 失敗。
- **Check `git status` after a suite run.** Scripts that write records will
  otherwise commit a measurement taken under machine load.
  **跑完測試後檢查 `git status`。** 否則會把機器負載下取得的量測提交進去。
