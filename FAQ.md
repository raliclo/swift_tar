# FAQ

Answers to questions that came up while running swift_tar across macOS,
Windows, WSL and a buildroot Linux VM. Every number here was measured; where a
measurement contradicted an earlier belief, the earlier belief is shown too, so
the correction is visible rather than quietly applied.

在 macOS、Windows、WSL 與 buildroot Linux VM 上執行 swift_tar 時所遇問題的解答。此處
每個數字皆為實測；凡量測結果推翻了先前的認知，該認知也一併列出，使更正可見，而非被
悄悄套用。

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

**The VM has no hardware acceleration.** Neither this VM nor the LinuxCS one
passes `-accel`, so QEMU falls back to TCG — every guest instruction is
translated in software. `qemu-system-aarch64 -accel help` lists `hvf`, and the
host is Apple silicon running an aarch64 guest, so HVF was available the whole
time. Measured cost of not using it:

| | TCG | HVF | ratio |
|---|---:|---:|---:|
| swift_tar `-n 1` | 5775 ms | 1165 ms | 4.96× |
| swift_tar `-n 4` | 3252 ms | 593 ms | 5.48× |
| bsdtar | 10969 ms | 2262 ms | 4.85× |

**Emulation costs about 5×, and it costs it uniformly.** This corrected a guess
of mine: I had expected TCG to punish *threaded* code specifically, because it
has to emulate atomics and memory barriers, and swift_tar's chunk pipeline
coordinates through semaphores. If that were the main effect, scaling would
improve markedly under HVF. It barely moves — 1.78× to 1.96×. TCG is a flat tax
on everything, not a thread-specific penalty.

**Only four vCPUs on a ten-core host.** `-smp` is the knob; nothing structural
prevents raising it.

**The pipeline has a serial section.** Chunks compress concurrently but must be
written back in order, and the input is read as one stream. That is the design's
ceiling, not a configuration mistake, and it is why even under HVF four threads
give 1.96× rather than 4×.

So: raising `-smp` and enabling `ACCEL=hvf` are both available and both help.
`run.sh` takes `ACCEL=hvf` and `SMP=n`; **the default stays TCG on purpose**,
because every earlier measurement in this repository was taken under TCG and
changing the default would silently invalidate them.

三項成因，其中兩項可改善。

**VM 完全沒有硬體加速。** 兩台 VM 都未傳入 `-accel`，QEMU 因而退回 TCG，逐一以軟體翻譯
guest 指令。而 `-accel help` 列有 `hvf`，主機是 Apple silicon 跑 aarch64 guest，HVF
一直都可用。不用它的代價實測約為 **5 倍，且是均勻的**。

這一點更正了我先前的猜測：我原以為 TCG 會特別懲罰**多執行緒**程式碼，因為它必須模擬
原子操作與記憶體屏障，而 swift_tar 的分塊管線正是靠 semaphore 協調。若那是主因，HVF
下的擴展性應大幅改善。實際幾乎沒動——1.78 倍變 1.96 倍。TCG 是對所有東西課的均一稅，
不是針對執行緒的懲罰。

**十核主機上只給四顆 vCPU**，`-smp` 即可調整。**管線本身有序列段**：分塊可並行壓縮，
但寫回必須保序，輸入亦為單一串流——這是設計的天花板而非組態失誤，也是即使在 HVF 下
四執行緒仍只有 1.96 倍的原因。

---

## Why is bsdtar faster than swift_tar in the VM?

## 為什麼 bsdtar 在 VM 裡比 swift_tar 快？

**It is not, in general. It depends entirely on the direction.**

Same guest, same 160 MB corpus, HVF:

| operation | swift_tar | bsdtar | winner |
|---|---:|---:|---|
| compress (`-c --gzip -n 4`) | **593 ms** | 2262 ms | swift_tar, 3.8× |
| extract bsdtar's archive | 189 ms | **61 ms** | bsdtar, 3.1× |
| extract swift_tar's archive | 165 ms | **58 ms** | bsdtar, 2.8× |

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

**But that does not explain the whole gap**, and the obvious explanations turn
out to be wrong. swift_tar's own archives *are* multi-member and therefore
*could* be decoded in parallel, yet bsdtar still extracts them ~3× faster.
Three hypotheses were tested and three failed:

*Per-entry overhead in swift_tar's extract path.* Disproven. Per-entry cost
would grow with the number of entries; the gap does the opposite. Total size
held at ~160 MB, entry count varied, medians of five on macOS and best-of-three
in the guest:

| entries × size | macOS ST | macOS bsdtar | ratio | VM ST | VM bsdtar | ratio |
|---|---:|---:|---:|---:|---:|---:|
| 20 × 8 MB | 166 ms | 74 ms | 2.24× | 138 ms | 40 ms | 3.45× |
| 200 × 800 KB | 114 ms | 83 ms | 1.37× | 105 ms | 42 ms | 2.50× |
| 2000 × 80 KB | 259 ms | 276 ms | **0.94×** | 183 ms | 118 ms | 1.55× |

The gap shrinks as entries multiply, and on macOS it reverses — swift_tar wins
at 2000 entries.

*A chunk-boundary effect at 4 MiB.* Disproven. Holding the total at 128 MB and
sweeping the single-file size across the boundary shows no discontinuity:
1 MB 1.16×, 4 MB 1.65×, 8 MB 1.58×, 32 MB 2.17×, 128 MB 1.56×.

*Something about the VM.* Disproven. The same curve appears on macOS, on real
disk, with no emulation involved.

What the measurements do support is narrower and duller: **swift_tar's extract
path has a lower throughput ceiling than bsdtar's, roughly independent of the
archive's shape.** swift_tar lands between 95 and 130 ms across every shape
above while bsdtar ranges from 60 to 82 ms, improving as the files get larger
and more sequential. And the gap is *widest* where I/O is cheapest — the guest
writes to tmpfs and shows worse ratios than macOS writing to disk — which points
at CPU-side work in the extract path rather than at I/O.

Naming that work would need profiling, which has not been done. Recorded as a
bounded open question, not a conclusion.

An earlier note in `build_multissh_in_linux_vm.zsh` recorded
`swift_tar -x 89 s vs bsdtar -xzf 52 s` and concluded swift_tar was slower. That
observation was right and the reasoning attached to it was right — but it
covered extraction only, and was generalised into "swift_tar is slower in the
VM", which the compression numbers above contradict. That case also carried its
own decisive evidence: decompress-only was **3.2 s for both tools**, against
52 s and 89 s for the full extraction. Its bottleneck was writing 3.3 GiB of
files, not decoding — where no choice of tar helps.

**並非一概如此，完全取決於方向。** 壓縮 swift_tar 快 3.8 倍，解壓 bsdtar 快約 3 倍。

不對稱源於格式而非工具優劣：**壓縮可並行**（swift_tar 切成 4 MiB 分塊並行壓縮，實測其
封存有 5 個 gzip 成員，bsdtar 只有 1 個）；**單一串流的解壓無法並行**（deflate 為滑動
視窗格式，第 N 個位元組必須先有其前的視窗）。

**但這無法解釋全部差距**，而顯而易見的那些解釋經檢驗皆不成立。swift_tar 自己的封存
**是**多成員、理論上**可以**並行解碼，bsdtar 卻仍快約 3 倍。三個假設，三個皆被否證：

*swift_tar 解壓路徑的逐項開銷。* 否證。逐項成本應隨項目數增加而擴大，實測方向相反
（上表：總量固定約 160 MB、僅改項目數，macOS 取五次中位數、guest 取三次最佳）。差距
隨項目變多而縮小，在 macOS 上並於 2000 項時反轉——swift_tar 反而較快。

*4 MiB 分塊邊界效應。* 否證。總量固定 128 MB、單檔大小跨越該邊界掃描，未見不連續：
1 MB 1.16×、4 MB 1.65×、8 MB 1.58×、32 MB 2.17×、128 MB 1.56×。

*與 VM 有關。* 否證。同樣的曲線在 macOS 的實體磁碟上就有，不涉及任何模擬。

量測真正支持的結論較窄也較平淡：**swift_tar 的解壓路徑吞吐量上限低於 bsdtar，且大致
與封存形狀無關。** 上述所有形狀下 swift_tar 落在 95–130 毫秒之間，bsdtar 則為 60–82
毫秒，且隨檔案變大、越趨循序而變快。而差距**在 I/O 最便宜時最大**——guest 寫入 tmpfs
的比值比 macOS 寫入磁碟更差——這指向解壓路徑的 CPU 側工作，而非 I/O。

要指出那是什麼工作需要 profiling，尚未進行。此處記為一個範圍明確的未決問題，而非結論。

`build_multissh_in_linux_vm.zsh` 先前記錄的 `swift_tar -x 89 秒 vs bsdtar -xzf 52 秒`
觀察無誤、推理亦無誤，但它只涵蓋解壓，卻被推廣為「swift_tar 在 VM 裡較慢」，而上方的
壓縮數字與之相反。該案例本身還帶有更強的證據：**僅解壓兩者都是 3.2 秒**，而完整解出為
52 與 89 秒——其瓶頸是寫入 3.3 GiB 檔案，不是解碼，那種情況換任何 tar 都無濟於事。

---

## For transferring files, should I use swift_tar or bsdtar?

## 傳輸檔案時該用 swift_tar 還是 bsdtar？

**Use swift_tar to pack and bsdtar to unpack.** The two formats are
interoperable — `verifications/tar_interop_matrix.zsh` passes 13/13 on macOS and
12/12 on Windows, in both directions, against both bsdtar and GNU tar — so the
two halves can be chosen independently.

On the numbers above, for one 160 MB payload, ignoring the network:

| pack → unpack | total |
|---|---:|
| swift_tar → bsdtar | **651 ms** |
| swift_tar → swift_tar | 758 ms |
| bsdtar → bsdtar | 2320 ms |
| bsdtar → swift_tar | 2451 ms |

The packing side dominates, which is why the mixed pairing wins: swift_tar's
parallel compression saves far more than bsdtar's faster extraction does.

**The size of the win depends on the payload's shape.** The table above uses
20 entries of 8 MB, which is where swift_tar's extraction is at its worst. With
many small files the extraction gap nearly closes — at 2000 × 80 KB on macOS
swift_tar is actually the faster extractor — so the mixed pairing matters most
for a few large files and hardly at all for a source tree.

**負載的形狀會改變優勢幅度。** 上表使用 20 個 8 MB 的項目，正是 swift_tar 解壓最不利
的形狀。檔案多而小時解壓差距幾乎消失——macOS 上 2000 × 80 KB 時 swift_tar 反而是較快
的解壓端——故混搭組合在「少數大檔」時效益最大，對一棵原始碼樹則幾乎無差別。

Three things that change the answer:

- **If the receiving side is write-bound, none of this matters.** The 1.05 GiB →
  3.3 GiB case above spent its time in the filesystem; both tools decompressed
  it in 3.2 s. Measure where the time actually goes before optimising the tar.
- **If you need encryption, it has to be swift_tar on both ends.** bsdtar cannot
  read a ChaCha20-Poly1305 container.
- **If the archive must be readable by an unknown third party**, plain
  `--gzip` from either tool is safe; the LZFSE-family codecs are not.

**打包用 swift_tar，解開用 bsdtar。** 兩者格式互通（互通矩陣在 macOS 13/13、Windows
12/12，雙向、且對 bsdtar 與 GNU tar 皆成立），故兩端可各自選擇。以 160 MB 負載計，
不計網路時間，混搭組合最快（651 毫秒），因為**打包端主導總時間**——swift_tar 並行壓縮
所省下的，遠多於 bsdtar 解壓所快的。

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
ACCEL=tcg ./run.sh '...'     # the default; every earlier record used it
ACCEL=hvf ./run.sh '...'     # Hypervisor.framework
SMP=8     ./run.sh '...'     # vCPU count
```

**Caveat on all of it**: the host was at load average 2.77 with 69% idle when
these were taken, and the numbers have not yet been repeated on an idle machine.
Ratios between tools measured in the same run are trustworthy; absolute
milliseconds are not. This repository has already been bitten once by a record
taken under load — a whole table came in uniformly 8% slower with the sizes
unchanged — which is why measurement scripts here write their records only when
`--record` is passed.

於本專案自有的 VM 內量測，每個組態各開機一次，語料為 160 MB 不可壓縮資料（同一份 8 MB
隨機檔複製 20 份，使 tar 有真實的逐項工作，而 codec 又不致找到跨檔冗餘）。時間取自
guest 內的 `date +%s%N`，故不含主機端的開機成本。

**所有數字的但書**：取樣時主機 load average 為 2.77、閒置 69%，尚未在完全閒置的機器上
重測。同一次執行內的**工具間比值**可信，**絕對毫秒數則否**。本程式庫已為「負載下取得的
紀錄」付過一次代價——整張表一致慢 8% 而體積不變——這也是此處量測腳本一律需傳
`--record` 才寫入紀錄的原因。
