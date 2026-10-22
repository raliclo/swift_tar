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
| 1 | 5775 ms | 1165 ms |
| 2 | 5541 ms | 1144 ms |
| 4 | **3252 ms** | **593 ms** |
| 8 | 3213 ms | 587 ms |

Threads help: 1 → 4 is **1.78×** under TCG and **1.96×** under HVF. Going to 8
changes nothing, because there are only four vCPUs — past the core count the
extra threads queue against each other.

不是。guest 看得到四顆，也確實在用。執行緒有效：1 → 4 在 TCG 下為 **1.78 倍**、HVF 下
為 **1.96 倍**。加到 8 沒有變化，因為只有四顆 vCPU——超過核心數之後，多出的執行緒只是
互相排隊。

---

## Why is the speed-up 1.78× and not 4×? Can it be improved?

## 為何加速只有 1.78 倍而非 4 倍？能改善嗎？

Three separate causes, and only two of them are fixable.

**The VM runs without hardware acceleration by default.** `run.sh` uses TCG
unless `ACCEL=hvf` is given — every guest instruction is translated in
software. The host is Apple silicon running an aarch64 guest, so HVF is
available. Measured cost of TCG:

| | TCG | HVF | ratio |
|---|---:|---:|---:|
| swift_tar `-n 1` | 5775 ms | 1165 ms | 4.96× |
| swift_tar `-n 4` | 3252 ms | 593 ms | 5.48× |
| bsdtar | 10969 ms | 2262 ms | 4.85× |

**Emulation costs about 5×, and it costs it uniformly.** TCG does not punish
threaded code specifically: thread scaling barely moves under HVF — 1.78× to
1.96×. TCG is a flat tax on everything, not a thread-specific penalty.

**Only four vCPUs on a ten-core host.** `-smp` is the knob; nothing structural
prevents raising it.

**The pipeline has a serial section.** Chunks compress concurrently but must be
written back in order, and the input is read as one stream. That is the design's
ceiling, not a configuration mistake, and it is why even under HVF four threads
give 1.96× rather than 4×.

So: raising `-smp` and enabling `ACCEL=hvf` are both available and both help.
`run.sh` takes `ACCEL=hvf` and `SMP=n`; the default is TCG with four vCPUs.

三項成因，其中兩項可改善。

**VM 預設沒有硬體加速。** 未指定 `ACCEL=hvf` 時 `run.sh` 使用 TCG，逐一以軟體翻譯
guest 指令。主機是 Apple silicon 跑 aarch64 guest，HVF 可用。TCG 的代價實測約為
**5 倍，且是均勻的**：HVF 下的執行緒擴展性幾乎沒動——1.78 倍變 1.96 倍。TCG 是對所有
東西課的均一稅，不是針對執行緒的懲罰。

**十核主機上只給四顆 vCPU**，`-smp` 即可調整。**管線本身有序列段**：分塊可並行壓縮，
但寫回必須保序，輸入亦為單一串流——這是設計的天花板而非組態失誤，也是即使在 HVF 下
四執行緒仍只有 1.96 倍的原因。

---

## Why is bsdtar faster than swift_tar in the VM?

## 為什麼 bsdtar 在 VM 裡比 swift_tar 快？

**It is not, in general. It depends on the direction and the platform.**

Compressing, the same guest and 160 MB corpus, HVF: swift_tar `-c --gzip -n 4`
takes **593 ms**, bsdtar 2262 ms — swift_tar is 3.8× faster.

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
| 20 × 8 MB | 59 / 54 ms = **1.09×** | 38 / 26 ms = **1.46×** |
| 200 × 800 KB | 43 / 57 ms = **0.75×** | 31 / 25 ms = **1.24×** |
| 2000 × 80 KB | 67 / 151 ms = **0.44×** | 50 / 35 ms = **1.43×** |

On macOS the two are about even on a few large files (bsdtar 1.09×), and
swift_tar is faster as the corpus fragments, up to 2.3× at 2000 entries. On
Linux bsdtar extracts 1.24× to 1.46×
faster, although swift_tar's own archives are multi-member and could be decoded
in parallel.

The two references are different versions — bsdtar 3.5.3 / libarchive 3.7.4 on
macOS against 3.8.8 / 3.8.8 on Linux — so platform is not the only variable
between those columns.

The cause of the Linux gap is not identified. Ruled out:

- *Per-entry overhead in swift_tar's extract path.* Per-entry cost would grow
  with the number of entries; the ratio does not.
- *A chunk-boundary effect at 4 MiB.* Holding the total at 128 MB and sweeping
  the single-file size across the boundary shows no discontinuity: 1 MB 1.16×,
  4 MB 1.65×, 8 MB 1.58×, 32 MB 2.17×, 128 MB 1.56×.
- *Per-file buffering in `FileWriterPool` as a source of page faults* (below).

**Profiling belongs on Linux**, which is also the only end where it is
feasible: on macOS the extract runs about 0.17 s and four separate sampling
approaches returned at most 52 samples (recorded in that folder's README).

**Page faults and per-file buffering.** `verifications/zstd_decode_gap.zsh`
splits "why is native slower" into facets measured one at a time and excludes
the E-cluster, the `-n` setting, and parallelism. `user` time is comparable
while `sys` is not, with page faults differing by about 64× (128,042 against
1,990). `verifications/page_fault_attribution.zsh` shows that per-file
buffering in `FileWriterPool` is not the source of those faults.

The `FileWriterPool.smallFileMax` check in the extract path is the switch: a
member of at most `smallFileMax` (4 MiB) is buffered whole into a `Data()`;
anything larger skips that path entirely. Sizing the members across 4 MiB
therefore turns the path on and off in one binary. Five corpora, seven
interleaved reps, minima taken, on a RAM disk, inter-rep variance under 1%:

| corpus | members | path | faults | per MiB | per 4 KiB page |
|---|---|---|---|---|---|
| C | 96 × 1 MiB | buffered | 8,144 | 84 | 0.33 |
| A | 32 × 3 MiB | buffered | 26,424 | 275 | 1.08 |
| D | 24 × 4 MiB | buffered | 26,206 | 272 | 1.07 |
| E | 24 × 5 MiB | inline | 28,086 | 234 | 0.91 |
| B | 16 × 6 MiB | inline | 20,482 | 213 | 0.83 |

D against E decides it: same member count, adjacent sizes, the branch flips, and
faults per page move smoothly from 1.07 to 0.91 — no discontinuity at the
boundary. C is the stronger refutation: it leans on the buffered path hardest, 96
members all taking it, and has the *fewest* faults. Were buffering the cause, C
would be the worst case rather than the best.

Faults per page varying continuously with allocation size, and not jumping when
the branch changes, is the shape of the allocator — macOS `malloc` mmaps and
munmaps large allocations, and the next one pays zero-fill page by page on first
touch. The inline path allocates per chunk, so it pays the same cost.

**Bounds, which must travel with this result.** It measures swift_tar extracting
synthetic, incompressible corpora. It is *not* a measurement of the 64× native
versus external gap itself; it answers only "is per-file buffering the source of
the faults", and the answer is no. Naming the allocation site needs a
per-symbol profile (`sample`, or Instruments' Allocations).

**A write-bound extraction.** Extracting a 1.05 GiB archive into 3.3 GiB of files
in the VM takes 89 s with swift_tar and 52 s with bsdtar, while decompress-only
is **3.2 s for both tools**. The bottleneck there is writing the files, not
decoding — where no choice of tar helps.

**並非一概如此，取決於方向與平台。** 壓縮時 swift_tar 快 3.8 倍；解壓在 macOS 上
swift_tar 較快，在 Linux 上 bsdtar 快 1.24 到 1.46 倍。

不對稱源於格式而非工具優劣：**壓縮可並行**（swift_tar 切成 4 MiB 分塊並行壓縮，實測其
封存有 5 個 gzip 成員，bsdtar 只有 1 個）；**單一串流的解壓無法並行**（deflate 為滑動
視窗格式，第 N 個位元組必須先有其前的視窗）。

**解壓取決於平台。** 同一支腳本、同樣三種形狀（總量固定約 160 MB、僅改項目數）、
兩個平台——見 [`verifications/profile/`](verifications/profile/README.md)，
swift_tar / bsdtar：

| 形狀 | macOS | Linux（QEMU aarch64） |
|---|---|---|
| 20 × 8 MB | 59 / 54 毫秒 = **1.09×** | 38 / 26 毫秒 = **1.46×** |
| 200 × 800 KB | 43 / 57 毫秒 = **0.75×** | 31 / 25 毫秒 = **1.24×** |
| 2000 × 80 KB | 67 / 151 毫秒 = **0.44×** | 50 / 35 毫秒 = **1.43×** |

macOS 上少量大檔時兩者相當（bsdtar 1.09 倍），語料愈碎 swift_tar 愈快，2000 項時快
2.3 倍。Linux 上 bsdtar 快
1.24 到 1.46 倍——儘管 swift_tar 自己的封存是多成員、理論上可以並行解碼。

兩端的參照實作版本不同——macOS 是 bsdtar 3.5.3 / libarchive 3.7.4，Linux 是 3.8.8 /
3.8.8——所以「平台」不是那兩欄之間唯一的變數。

Linux 上這個差距的成因尚未確定。已排除：

- *swift_tar 解壓路徑的逐項開銷。* 逐項成本應隨項目數增加而擴大，比值並未如此。
- *4 MiB 分塊邊界效應。* 總量固定 128 MB、單檔大小跨越該邊界掃描，未見不連續：
  1 MB 1.16×、4 MB 1.65×、8 MB 1.58×、32 MB 2.17×、128 MB 1.56×。
- *`FileWriterPool` 的逐檔緩衝作為 page fault 來源*（見下）。

**profile 要在 Linux 上做**，而那也是唯一做得到的一端：macOS 上解壓只跑約 0.17 秒，
四種取樣做法最多只取到 52 個樣本（記於該資料夾的 README）。

**page fault 與逐檔緩衝。** `verifications/zstd_decode_gap.zsh` 把「native 為何較慢」
拆成可逐項量測的面向，排除了 E-cluster、`-n` 設定、平行度。`user` 時間相近而 `sys`
不同，page fault 相差約 64 倍（128,042 對 1,990）。`verifications/page_fault_attribution.zsh`
顯示 `FileWriterPool` 的逐檔緩衝不是這些 fault 的來源。

解壓路徑中對 `FileWriterPool.smallFileMax` 的判斷**就是那個開關**。成員
大小不超過 `smallFileMax`（4 MiB）者整份緩衝進 `Data()`，更大者完全跳過該路徑。因此只要
讓成員大小跨過 4 MiB，就能在同一個執行檔上把這條路徑開開關關。五個語料、七輪交錯、取
最小值、於 RAM disk 上進行，輪間變異低於 1%：

| 語料 | 成員 | 路徑 | page fault | 每 MiB | 每 4 KiB 分頁 |
|---|---|---|---|---|---|
| C | 96 × 1 MiB | 緩衝 | 8,144 | 84 | 0.33 |
| A | 32 × 3 MiB | 緩衝 | 26,424 | 275 | 1.08 |
| D | 24 × 4 MiB | 緩衝 | 26,206 | 272 | 1.07 |
| E | 24 × 5 MiB | inline | 28,086 | 234 | 0.91 |
| B | 16 × 6 MiB | inline | 20,482 | 213 | 0.83 |

決定性的是 D 與 E：成員數相同、大小相鄰、分支翻面，而每頁 fault 由 1.07 平順走到 0.91
——分界處沒有不連續。C 是更強的反證：它把緩衝路徑用得最重（96 個成員全部走它），fault
卻**最少**。若緩衝是成因，C 應是最壞的情況，而非最好的。

每頁 fault 隨單次配置的大小連續變化、且跨越分支時不跳動，這個形狀指向配置器——macOS 的
`malloc` 對大配置採 mmap／munmap，下一次配置在首次觸碰時逐頁 zero-fill。inline 路徑同樣
逐塊配置，因此付同樣的代價。

**界限必須與這個結果一起被引用。** 它量的是 swift_tar 在合成、不可壓縮語料上的解壓，
**不是** native 對 external 那個 64 倍差距本身；它只回答「逐檔緩衝是不是 fault 的來源」，
答案是否。要指出配置點需要逐符號 profile（`sample`，或 Instruments 的 Allocations）。

**受限於寫入的解壓。** 在 VM 內把 1.05 GiB 的封存解成 3.3 GiB 的檔案，swift_tar 需
89 秒、bsdtar 需 52 秒，而**僅解壓兩者都是 3.2 秒**——瓶頸是寫入檔案，不是解碼，那種
情況換任何 tar 都無濟於事。

---

## For transferring files, should I use swift_tar or bsdtar?

## 傳輸檔案時該用 swift_tar 還是 bsdtar？

**Use swift_tar to pack.** The two formats are interoperable —
`verifications/tar_interop_matrix.zsh` passes 13/13 on macOS and 12/12 on
Windows, in both directions, against both bsdtar and GNU tar — so the two halves
can be chosen independently.

The packing side dominates: for one 160 MB payload swift_tar's parallel
compression saves about 1.7 s (593 ms against 2262 ms), while the extraction
difference on the same scale is tens of milliseconds either way. For unpacking,
swift_tar is faster on macOS once there are many files, and bsdtar on Linux (see
the previous answer).

Three things that change the answer:

- **If the receiving side is write-bound, none of this matters.** The 1.05 GiB →
  3.3 GiB case above spends its time in the filesystem; both tools decompressed
  it in 3.2 s. Measure where the time actually goes before optimising the tar.
- **If you need encryption, it has to be swift_tar on both ends.** bsdtar cannot
  read a ChaCha20-Poly1305 container.
- **If the archive must be readable by an unknown third party**, plain
  `--gzip` from either tool is safe; the LZFSE-family codecs are not.

**打包用 swift_tar。** 兩者格式互通（互通矩陣在 macOS 13/13、Windows 12/12，雙向、
且對 bsdtar 與 GNU tar 皆成立），故兩端可各自選擇。**打包端主導總時間**：以 160 MB
負載計，swift_tar 並行壓縮省下約 1.7 秒（593 對 2262 毫秒），而同規模下解壓的差距
無論哪一方較快都只有數十毫秒。解開時，macOS 上檔案一多 swift_tar 較快、Linux 上 bsdtar 較快
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
