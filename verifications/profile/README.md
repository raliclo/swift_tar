# verifications/profile — 各平台的效能量測資料 / per-platform performance data

這個資料夾存放**各平台的效能量測結果**，以及產生它們的腳本。它與 `verifications/` 其餘
部分的差別在於：那些回答「對不對」，這裡回答「多快」，而後者遠比前者容易得到看似可信
的假答案。

This folder holds per-platform performance measurements and the script that produces them.
The rest of `verifications/` answers "is it correct"; this answers "how fast", and the
second question yields plausible-looking wrong answers far more readily than the first.

---

## 檔案 / Files

| 檔案 | 內容 |
|---|---|
| `extract_shapes.zsh` | 量測腳本。三種形狀、交錯執行、取最小值。`--record` 才寫檔 |
| `extract_shapes.csv2` | 累積的結果。雙列標頭（英文、繁中），一律經 `csv2` 讀寫 |

追加式，不覆寫。同一平台的多次量測是**要保留的**——效能會隨程式碼與機器狀態改變，
而唯一能看出「改變了」的方法就是留著舊的那幾列。

Append-only. Repeated rows for one platform are the point: performance moves with the code
and with the machine, and the only way to see that it moved is to keep the earlier rows.

---

## 怎麼跑 / How to run

```zsh
# 先建置，再量測。量一個舊的執行檔是這個資料夾最常見的無聲錯誤。
./build.zsh                                    # 或 ./compile_tar-linux.zsh
verifications/profile/extract_shapes.zsh       # 印出，不寫檔
verifications/profile/extract_shapes.zsh --record
```

**語料要放在 I/O 最便宜的地方。** 預設會挑一個平台相稱的位置，但 macOS 的 `$TMPDIR`
在開機磁碟上——那是真磁碟。在 macOS 上請自備 RAM disk：

```zsh
DEV=$(hdiutil attach -nomount ram://3145728)   # 1.5 GB
diskutil eraseVolume HFS+ prof "$DEV"
verifications/profile/extract_shapes.zsh --work /Volumes/prof/w --record
hdiutil detach "$DEV"
```

理由不是速度好看，是**要量的東西會被磁碟埋掉**。FAQ 對這個差距的結論是「差距在 I/O
最便宜時最大」；在真磁碟上量到的是磁碟，不是 tar。實測：同一份 1.2 GB 語料在開機碟上
是 real 2.04 秒而 CPU 僅 0.54 秒——四分之三的時間在等，量不到任何東西。

The corpus belongs where I/O is cheapest, and not for flattering numbers: on a real disk
the disk is what you measure. Measured: the same 1.2 GB corpus on the boot SSD took 2.04 s
wall for 0.54 s of CPU — three quarters of it waiting.

---

## 四個會讓數字說謊的陷阱 / Four traps that make the numbers lie

### 1. 參照 tar 要以「自我描述」挑選，絕不以檔名

Linux VM 的 `/usr/bin/tar` **就是 swift_tar**，以該名稱安裝；busybox tar 在 `/bin/tar`，
bsdtar 在 `/usr/bin/bsdtar`。依檔名挑選會讓 swift_tar 與自己比較，而結果會是一個漂亮的
1.00×——一個完全錯誤、完全可信的數字。

`extract_shapes.zsh` 逐一詢問候選者 `--version`，只接受自稱 bsdtar 或 GNU tar 的。

`/usr/bin/tar` in the Linux VM *is* swift_tar under that name. Choosing by filename
compares swift_tar with itself and reports a beautiful 1.00x. The script asks each
candidate what it is and accepts only bsdtar or GNU tar.

### 2. 機器忙的時候量到的是機器

本樹的 `mistakes.md` 第 2 條記著六次假差異，全部在複量後消失。腳本會把當下的 load
average 記進每一列——**不是裝飾，是讓後來的人能判斷該不該相信那一列**。

交錯執行並取最小值，是為了對抗這件事：交錯讓兩者遇到同一段背景負載；干擾只會使時間
變長不會變短，故最小值最接近「沒有干擾」的那一次。但這只降低雜訊，不能救一台 load 15
的機器。**如果 loadavg 那一欄很大，那一列就只能當成下限。**

### 3. 這支腳本看不到 codec 的任何改動——語料是未壓縮的 tar

`extract_shapes.zsh` 以 `"$BIN" -c -f "$WORK/a.tar"` 產生語料,**沒有壓縮旗標**。所以
liblzma、liblz4、libzstd 在整輪量測中**一次都沒有被呼叫**。

這件事值得寫下來,因為 `sync_all.zsh` 在移動任何 pin 之後都會列出「第 5 步:效能可能改變,
`extract_shapes.zsh --record`」,而那一步在 codec pin 移動之後**不會驗到任何東西**。
2026-09-25 就是這樣:xz 由 5.8.3 升到 5.8.4、三個 codec 由 homebrew 動態連結改為 submodule
靜態連結,而這支腳本量到的形狀完全不經過它們。那一輪的數字是誠實的,只是它回答的不是
「codec 換了之後如何」這個問題。

要量 codec,需要壓縮過的形狀——`test/test_swift_tar_rgb1.zsh` 的 codec 表已經逐一跑
gzip／bzip2／xz／zstd／lz4 並印出 MB/s,那裡才看得到。本資料夾刻意只量「純 tar 的解壓
路徑」,因為 FAQ 的解壓差距問題就是在那條路徑上。

`extract_shapes.zsh` builds its corpus with no compression flag, so liblzma, liblz4 and
libzstd are never called during a run. Worth recording, because `sync_all.zsh` prints
"step 5: performance may have moved, run `extract_shapes.zsh --record`" after *any* pin
move, and after a codec pin move that step verifies nothing. That happened on 2026-09-25.
The numbers from such a round are honest; they simply do not answer the question asked.
For codecs, use the codec table in `test/test_swift_tar_rgb1.zsh`, which times each one.

### 4. 取樣式 profiler 在這個目標上無效——這是量過的，不是猜的

2026-09-06 在 macOS 上試了四種做法要取 symbol profile，全部失敗，因為**解壓一個 RAM
disk 上的封存只跑約 0.17 秒**：

| 做法 | 結果 |
|---|---|
| `sample <pid>` | 附掛慢於行程壽命，0 個樣本 |
| `sample -wait swift_tar` | 同上，0 個 |
| `xctrace record --template 'CPU Profiler' --launch` | **52 個樣本**，排不出名次 |
| 同上，但錄一個跑 25 次的 zsh 迴圈 | 13 個樣本，**全部落在 `loop.zsh`**——`--launch` 不追子行程 |

要讓單一行程跑得夠久就得放大語料，而語料必須在記憶體裡；當時 swap 已用掉 5.97 GB /
7.17 GB，把 RAM disk 撐大會擾動的正是要量的配置器與 page fault 行為。

**所以先量時間、確認差距存在，再談 profile。** profile 一個不存在的差距是浪費，而且
更糟——它一定會找到「某個最花時間的函式」，然後那個函式會被當成成因。

Four sampling approaches were tried on macOS on 2026-09-06 and all failed, because the
target runs about 0.17 s. Establish that a gap exists before profiling one: a profiler
always returns some hottest function, and that function then gets mistaken for the cause.

---

## 為什麼從「量時間」開始，而不是從 profile 開始

FAQ 的「解壓差距」一節提出過三個機制，每一個都在下一組數字出現時倒下；第四個候選
（`FileWriterPool` 的逐檔緩衝）也被 `page_fault_attribution.zsh` 排除。

在指名第五個機制之前，要先確認**那個現象還在**。這個資料夾的第一批資料就是為此而量的。

The FAQ's decode-gap section named three mechanisms and each fell to the next set of
numbers; a fourth candidate was excluded separately. Before naming a fifth, confirm the
phenomenon still exists. That is what the first rows here were measured to check.

---

## 第一批資料說了什麼 / What the first rows say

2026-09-06，兩個平台、同樣三種形狀、同樣的腳本：

| 形狀 | macOS | Linux (QEMU aarch64) |
|---|---|---|
| 20 × 8 MB | 70 / 76 ms = **0.92×** | 38 / 26 ms = **1.46×** |
| 200 × 800 KB | 47 / 61 ms = **0.77×** | 31 / 25 ms = **1.24×** |
| 2000 × 80 KB | 85 / 156 ms = **0.54×** | 50 / 35 ms = **1.43×** |

**那個差距是真的，而且是 Linux 專有的。** 在 Linux 上 swift_tar 慢 1.24–1.46 倍，三種
形狀一致；在 macOS 上它反而比 bsdtar 快，而且愈碎的語料領先愈多。

這同時說明 FAQ 那一節裡關於 macOS 的敘述已不成立：它寫著「swift_tar 落在 95–130 ms 而
bsdtar 為 60–82 ms」，今天量到的是 swift_tar 47–85 ms、bsdtar 61–156 ms。

**因此 profile 要在 Linux 上做，不是在 macOS 上。** 而那也剛好是可行的一端：guest 的
行程壽命與工具鏈都允許取樣，macOS 這邊不允許（見上方陷阱 3）。

**一個必須說出來的干擾項**：兩端的參照實作不同版本——macOS 是 bsdtar 3.5.3 /
libarchive 3.7.4，Linux 是 bsdtar 3.8.8 / libarchive 3.8.8。所以「平台」不是兩組數字
之間唯一的變數，libarchive 差了四個小版本。要把差距完全歸給平台，得先在同一個平台上
換掉參照版本再量一次。**這裡不做那個宣稱。**

Measured on 2026-09-06 across two platforms with the same script and shapes: the gap is
real and Linux-specific — 1.24x to 1.46x there, consistently, while on macOS swift_tar is
now the faster of the two and its lead grows as the corpus gets more fragmented. So
profiling belongs on Linux, which is also the end where sampling is feasible.

One confound stated plainly: the two references are different versions (bsdtar 3.5.3 /
libarchive 3.7.4 on macOS, 3.8.8 / 3.8.8 on Linux), so platform is not the only variable
between the two columns. No claim is made here that it is.

---

## 已完成的量測 / Measurements taken

- [`pgo-linux-20260906.md`](pgo-linux-20260906.md) — Linux 的逐函式計數(LLVM PGO)。
  結論是**否定的**:那些時間不在 swift_tar 自己的 Swift 程式碼裡。解開 160 MB 只讓
  被儀器化的區塊執行 21,743 次,`readExactly` 全場 63 次,**沒有任何計數隨位元組數
  成長**。選 PGO 而非取樣,是因為計數與機器負載無關——當時 load 4.63,其中最大宗是
  另一個專案的 Android 模擬器。
  Per-function counts on Linux. A negative result: the time is not in swift_tar's own
  Swift code — 21,743 instrumented counter increments for 160 MB, and nothing that
  scales with bytes. PGO was chosen over sampling because counts are load-independent.

- **2026-09-25,macOS 重量一輪**(`extract_shapes.csv2` 的第二組 mac 列,戳記
  `20260920-170352`,reps 10,RAM disk,load 3.72)。這是 `sync_all.zsh` 升級流程第 5 步,
  在 xz 5.8.3→5.8.4 與「三個 codec 改為 submodule 靜態連結」之後補做的。

  | 形狀 | 08-16 swift/ref/比值 (load 2.00) | 09-25 swift/ref/比值 (load 3.72) |
  |---|---|---|
  | 20x8MB | 70 / 76 / **0.92** | 59 / 54 / **1.09** |
  | 200x800KB | 47 / 61 / **0.77** | 43 / 57 / **0.75** |
  | 2000x80KB | 85 / 156 / **0.54** | 67 / 151 / **0.44** |

  **不要把這裡的任何變化歸給那兩次升級。** 三個理由,每一個單獨就足夠:

  1. 語料是未壓縮的 tar,**codec 一次都沒被呼叫**(見上方陷阱 3)。
  2. 兩輪之間相隔五週,swift_tar 自己有 `./` 前綴、mtime/pax 等多筆改動,macOS 與 Xcode
     也都動過。靜態連結不是唯一的變數,甚至不是最可能的那個。
  3. load 由 2.00 變成 3.72,故**絕對毫秒不可並排**;交錯取最小值讓比值仍可比,但
     20x8MB 那個 0.92→1.09 的幅度(約 18%)正落在本樹六次「複量後消失」的假差異範圍內
     (+9.5%、+13.6%、−10.7%、+21%、+22.4%)。單獨一輪不足以下結論。

  **能說的是**:swift_tar 在三個形狀上的絕對時間都比 08-16 那輪更快(70→59、47→43、
  85→67),而且是在負載更高的機器上。沒有看到回歸。macOS 上 swift_tar 仍是兩者中較快的
  一端(2000x80KB 為 0.44×),與「差距是 Linux 限定」的既有結論一致。

  A macOS round taken after the xz and static-codec changes, as step 5 of sync_all's
  checklist. Attribute none of the movement to those changes: the corpus is an
  uncompressed tar so no codec is called, five weeks and several swift_tar commits sit
  between the rounds, and loadavg went 2.00 → 3.72 so absolute milliseconds are not
  comparable. What can be said is that swift_tar is faster in absolute terms on all three
  shapes despite the higher load, and remains the faster of the two on macOS.
