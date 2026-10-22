# FAQ

Answers to questions that came up while running swift_tar across macOS,
Windows, WSL and a buildroot Linux VM. Every number here was measured.

在 macOS、Windows、WSL 與 buildroot Linux VM 上執行 swift_tar 時所遇問題的解答。此處
每個數字皆為實測。

For the RGB1 container see [`rgb1/FAQ.md`](rgb1/FAQ.md); for the
cross-platform verification procedure see
[`verifications/flow.md`](verifications/flow.md).

---

## Does the Linux VM support multiple cores?

## Linux VM 支援多核心嗎？

**Q: swift_tar is slow in the VM. Is it running on one core?**
**Q: swift_tar 在 VM 裡很慢，是不是只跑在一顆核心上？**

No. The guest sees four, and uses them.

```
nproc                    4
/proc/cpuinfo processor  4
QEMU                     -smp 4
host                     Apple M4, 10 cores
```

Measured in the guest, 160 MB corpus, `-c --gzip`:

| `-n` | TCG | HVF |
|---|---:|---:|
| 1 | 9483 ms | 2230 ms |
| 2 | 4954 ms | 1137 ms |
| 4 | **2897 ms** | **599 ms** |
| 8 | 2976 ms | 605 ms |

Threads help: 1 → 4 is **3.27×** under TCG and **3.72×** under HVF. Going to 8
changes nothing, because there are only four vCPUs — past the core count the
extra threads queue against each other.

不是。guest 看得到四顆，也確實在用。執行緒有效：1 → 4 在 TCG 下為 **3.27 倍**、HVF 下
為 **3.72 倍**。加到 8 沒有變化，因為只有四顆 vCPU——超過核心數之後，多出的執行緒只是
互相排隊。

---

## Why is the speed-up below 4×? Can it be improved?

## 為何加速不到 4 倍？能改善嗎？

Three separate causes, and two of them are fixable.

**The VM runs without hardware acceleration by default.** `run.sh` uses TCG
unless `ACCEL=hvf` is given — every guest instruction is translated in
software. The host is Apple silicon running an aarch64 guest, so HVF is
available. Measured cost of TCG:

| | TCG | HVF | ratio |
|---|---:|---:|---:|
| swift_tar `-n 1` | 9483 ms | 2230 ms | 4.25× |
| swift_tar `-n 4` | 2897 ms | 599 ms | 4.84× |
| bsdtar | 10988 ms | 2238 ms | 4.91× |

**Emulation costs about 4–5×, and slightly more for threaded code.** Thread
scaling from 1 to 4 is 3.27× under TCG against 3.72× under HVF.

**Only four vCPUs on a ten-core host.** `-smp` is the knob; nothing structural
prevents raising it.

**The pipeline has a serial section.** Chunks compress concurrently but must be
written back in order, and the input is read as one stream. That is why four
threads give 3.72× under HVF rather than 4×.

So: raising `-smp` and enabling `ACCEL=hvf` are both available and both help.
`run.sh` takes `ACCEL=hvf` and `SMP=n`; the default is TCG with four vCPUs.

三項成因，其中兩項可改善。

**VM 預設沒有硬體加速。** 未指定 `ACCEL=hvf` 時 `run.sh` 使用 TCG，逐一以軟體翻譯
guest 指令。主機是 Apple silicon 跑 aarch64 guest，HVF 可用。TCG 的代價實測約為
**4 到 5 倍，對多執行緒的程式碼略高**：1 → 4 的擴展在 TCG 下為 3.27 倍，HVF 下為 3.72 倍。

**十核主機上只給四顆 vCPU**，`-smp` 即可調整。**管線本身有序列段**：分塊可並行壓縮，
但寫回必須保序，輸入亦為單一串流——這是 HVF 下四執行緒為 3.72 倍而非 4 倍的原因。

---

## Why is bsdtar faster than swift_tar in the VM?

## 為什麼 bsdtar 在 VM 裡比 swift_tar 快？

**It is not, in general. It depends on the direction and the platform.**

Compressing, the same guest and 160 MB corpus, HVF: swift_tar `-c --gzip -n 4`
takes **599 ms**, bsdtar 2238 ms — swift_tar is 3.7× faster.

The asymmetry is in the format, not the tools' quality:

**Compression parallelises.** swift_tar splits the byte stream into 4 MiB
chunks and compresses them concurrently. Verified by counting real gzip members
(decoding each and following `unused_data`, not grepping for the `1f 8b` magic,
which occurs by chance inside compressed data):

```
swift_tar's .tgz   5 gzip members   (an 18 MB corpus, ~4 MiB per chunk)
bsdtar's .tgz      1 member         (a single stream)
```

**Single-stream decompression does not parallelise.** deflate is a
sliding-window format: byte N cannot be decoded without the window that
precedes it. Against bsdtar's single-member archive there is no parallelism to
exploit at all.

**Extraction depends on the platform.** Same script, same three shapes (total
held at ~160 MB, entry count varied), both platforms —
[`verifications/profile/`](verifications/profile/README.md), swift_tar /
bsdtar:

| shape | macOS | Linux (QEMU aarch64) |
|---|---|---|
| 20 × 8 MB | 34 / 73 ms = **0.47×** | 24 / 27 ms = **0.89×** |
| 200 × 800 KB | 53 / 89 ms = **0.60×** | 47 / 28 ms = **1.68×** |
| 2000 × 80 KB | 84 / 194 ms = **0.43×** | 51 / 38 ms = **1.34×** |

On macOS swift_tar is the faster extractor on all three shapes, about 1.7× to
2.3×. On Linux the two are about even on a few large files, and bsdtar extracts
1.3× to 1.7× faster once the corpus fragments, although swift_tar's own archives
are multi-member and could be decoded in parallel. Single extractions here last
tens of milliseconds, so the Linux ratios move by a few tenths between runs.

The two references are different versions — bsdtar 3.5.3 / libarchive 3.7.4 on
macOS against 3.8.9 / 3.8.9 on Linux — so platform is not the only variable
between those columns. The cause of the Linux gap on small files is not
identified.

**Profiling belongs on Linux**, which is also the only end where it is
feasible: on macOS each extract runs under 0.1 s, too short for a sampling
profiler (recorded in that folder's README).

**Native zstd against the external `zstd`.** `verifications/zstd_decode_gap.zsh`
extracts the same claw-code tree from a native zstd archive and through the
external `zstd` binary. On macOS the native path is faster (1.29 s against
2.13 s real) while taking about 13× the page faults (26,490 against 1,963).

**Page faults and per-file buffering.** The `FileWriterPool.smallFileMax` check
in the extract path is a switch: a member of at most `smallFileMax` (4 MiB) is
buffered whole into a `Data()`; anything larger skips that path. Sizing the
members across 4 MiB therefore turns the path on and off in one binary.
`verifications/page_fault_attribution.zsh`, five corpora, seven interleaved reps,
minima taken, on a RAM disk:

| corpus | members | path | faults | per MiB |
|---|---|---|---|---|
| C | 96 × 1 MiB | buffered | 1,663 | 17 |
| A | 32 × 3 MiB | buffered | 19,941 | 207 |
| D | 24 × 4 MiB | buffered | 14,394 | 149 |
| E | 24 × 5 MiB | inline | 1,497 | 12 |
| B | 16 × 6 MiB | inline | 1,490 | 15 |

Buffered members of 3–4 MiB take about ten times the faults per MiB of inline
members, while buffered 1 MiB members do not. The faults follow the size of the
buffer, not the buffered path as such. Each extraction above lasts well under
0.1 s, so the faults cost little time; naming the allocation site needs a
per-symbol profile (`sample`, or Instruments' Allocations).

**並非一概如此，取決於方向與平台。** 壓縮時 swift_tar 快 3.7 倍；解壓在 macOS 上
swift_tar 較快，在 Linux 上大檔兩者相當、小檔 bsdtar 快 1.3 到 1.7 倍。

不對稱源於格式而非工具優劣：**壓縮可並行**（swift_tar 切成 4 MiB 分塊並行壓縮，實測其
封存有 5 個 gzip 成員，bsdtar 只有 1 個）；**單一串流的解壓無法並行**（deflate 為滑動
視窗格式，第 N 個位元組必須先有其前的視窗）。

**解壓取決於平台。** 同一支腳本、同樣三種形狀（總量固定約 160 MB、僅改項目數）、
兩個平台——見 [`verifications/profile/`](verifications/profile/README.md)，
swift_tar / bsdtar：

| 形狀 | macOS | Linux（QEMU aarch64） |
|---|---|---|
| 20 × 8 MB | 34 / 73 毫秒 = **0.47×** | 24 / 27 毫秒 = **0.89×** |
| 200 × 800 KB | 53 / 89 毫秒 = **0.60×** | 47 / 28 毫秒 = **1.68×** |
| 2000 × 80 KB | 84 / 194 毫秒 = **0.43×** | 51 / 38 毫秒 = **1.34×** |

macOS 上三種形狀都是 swift_tar 較快，約 1.7 到 2.3 倍。Linux 上少量大檔時兩者相當，
語料一碎 bsdtar 就快 1.3 到 1.7 倍——儘管 swift_tar 自己的封存是多成員、理論上可以並行
解碼。這裡單次解壓只有數十毫秒，所以 Linux 的比值在不同次執行之間會差零點幾。

兩端的參照實作版本不同——macOS 是 bsdtar 3.5.3 / libarchive 3.7.4，Linux 是 3.8.9 /
3.8.9——所以「平台」不是那兩欄之間唯一的變數。Linux 上小檔差距的成因尚未確定。

**profile 要在 Linux 上做**，而那也是唯一做得到的一端：macOS 上每次解壓不到 0.1 秒，
對取樣式 profiler 來說太短（記於該資料夾的 README）。

**native zstd 對外部 `zstd`。** `verifications/zstd_decode_gap.zsh` 把同一棵 claw-code
分別從 native zstd 封存、以及經由外部 `zstd` 解出。macOS 上 native 較快（real 1.29 對
2.13 秒），page fault 則約為 13 倍（26,490 對 1,963）。

**page fault 與逐檔緩衝。** 解壓路徑中對 `FileWriterPool.smallFileMax` 的判斷是一個開關：
成員大小不超過 `smallFileMax`（4 MiB）者整份緩衝進 `Data()`，更大者跳過該路徑。因此只要
讓成員大小跨過 4 MiB，就能在同一個執行檔上把這條路徑開開關關。
`verifications/page_fault_attribution.zsh`，五個語料、七輪交錯、取最小值、於 RAM disk 上：

| 語料 | 成員 | 路徑 | page fault | 每 MiB |
|---|---|---|---|---|
| C | 96 × 1 MiB | 緩衝 | 1,663 | 17 |
| A | 32 × 3 MiB | 緩衝 | 19,941 | 207 |
| D | 24 × 4 MiB | 緩衝 | 14,394 | 149 |
| E | 24 × 5 MiB | inline | 1,497 | 12 |
| B | 16 × 6 MiB | inline | 1,490 | 15 |

3–4 MiB 的緩衝成員，每 MiB 的 fault 約為 inline 成員的十倍，而 1 MiB 的緩衝成員則否。
fault 跟著緩衝的大小走，不是跟著緩衝路徑本身。上表每次解壓都遠低於 0.1 秒，fault 花掉的
時間很少；要指出配置點需要逐符號 profile（`sample`，或 Instruments 的 Allocations）。

---

## For transferring files, should I use swift_tar or bsdtar?

## 傳輸檔案時該用 swift_tar 還是 bsdtar？

**Use swift_tar to pack.** The two formats are interoperable —
`verifications/tar_interop_matrix.zsh` passes 13/13 on macOS and 12/12 on
Windows, in both directions, against both bsdtar and GNU tar — so the two halves
can be chosen independently.

The packing side dominates: for one 160 MB payload swift_tar's parallel
compression saves about 1.6 s (599 ms against 2238 ms), while the extraction
difference on the same scale is tens of milliseconds either way. For unpacking,
swift_tar is faster on macOS, and bsdtar on Linux once there are many small files
(see the previous answer).

Three things that change the answer:

- **If the receiving side is write-bound, none of this matters.** When writing
  the files takes longer than decoding them, the choice of tar changes little.
  Measure where the time actually goes before optimising the tar.
- **If you need encryption, it has to be swift_tar on both ends.** bsdtar cannot
  read a ChaCha20-Poly1305 container.
- **If the archive must be readable by an unknown third party**, plain
  `--gzip` from either tool is safe; the LZFSE-family codecs are not.

**打包用 swift_tar。** 兩者格式互通（互通矩陣在 macOS 13/13、Windows 12/12，雙向、
且對 bsdtar 與 GNU tar 皆成立），故兩端可各自選擇。**打包端主導總時間**：以 160 MB
負載計，swift_tar 並行壓縮省下約 1.6 秒（599 對 2238 毫秒），而同規模下解壓的差距
無論哪一方較快都只有數十毫秒。解開時，macOS 上 swift_tar 較快，Linux 上小檔一多則 bsdtar 較快
（見上一題）。

三種會改變答案的情況：接收端若受限於寫入，則以上皆無意義（請先量測時間實際花在哪裡）；
需要加密時兩端都必須是 swift_tar（bsdtar 讀不了 ChaCha20-Poly1305 容器）；封存若須供
未知第三方讀取，兩者的 `--gzip` 皆安全，LZFSE 家族則否。

---

## How were these measured?

## 這些數字如何量得？

In the project's own VM, `~/projWin/VM-test/run.sh`, one boot per configuration,
160 MB corpus of incompressible data (20 copies of the same 8 MB random file, so
the tar has real per-entry work without the codec finding cross-file
redundancy). Times from `date +%s%N` inside the guest, so host-side boot cost is
excluded.

```sh
ACCEL=tcg ./run.sh '...'     # the default
ACCEL=hvf ./run.sh '...'     # Hypervisor.framework
SMP=8     ./run.sh '...'     # vCPU count
```

**Caveat on all of it**: the host was at load average 2.77 with 69% idle when
these were taken, and the numbers have not been repeated on an idle machine.
Ratios between tools measured in the same run are trustworthy; absolute
milliseconds are not. Measurement scripts here write their records only when
`--record` is passed.

於本專案自有的 VM 內量測，每個組態各開機一次，語料為 160 MB 不可壓縮資料（同一份 8 MB
隨機檔複製 20 份，使 tar 有真實的逐項工作，而 codec 又不致找到跨檔冗餘）。時間取自
guest 內的 `date +%s%N`，故不含主機端的開機成本。

**所有數字的但書**：取樣時主機 load average 為 2.77、閒置 69%，未在完全閒置的機器上
重測。同一次執行內的**工具間比值**可信，**絕對毫秒數則否**。此處量測腳本一律需傳
`--record` 才寫入紀錄。
