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

注意:`sync_all.zsh` 在移動任何 pin 之後都會列出「第 5 步:效能可能改變,
`extract_shapes.zsh --record`」,而那一步在 codec pin 移動之後**不會驗到任何東西**——
這支腳本量到的形狀完全不經過 codec。

要量 codec,需要壓縮過的形狀——`test/test_swift_tar_rgb1.zsh` 的 codec 表已經逐一跑
gzip／bzip2／xz／zstd／lz4 並印出 MB/s,那裡才看得到。本資料夾刻意只量「純 tar 的解壓
路徑」,因為 FAQ 的解壓差距問題就是在那條路徑上。

`extract_shapes.zsh` builds its corpus with no compression flag, so liblzma, liblz4 and
libzstd are never called during a run. `sync_all.zsh` prints "step 5: performance may
have moved, run `extract_shapes.zsh --record`" after *any* pin move, and after a codec pin
move that step verifies nothing. For codecs, use the codec table in `test/test_swift_tar_rgb1.zsh`, which times each one.

### 4. 取樣式 profiler 在這個目標上無效——這是量過的，不是猜的

在 macOS 上取 symbol profile 的四種做法全部失敗，因為**解壓一個 RAM disk 上的封存只跑
約 0.17 秒**：

| 做法 | 結果 |
|---|---|
| `sample <pid>` | 附掛慢於行程壽命，0 個樣本 |
| `sample -wait swift_tar` | 同上，0 個 |
| `xctrace record --template 'CPU Profiler' --launch` | **52 個樣本**，排不出名次 |
| 同上，但錄一個跑 25 次的 zsh 迴圈 | 13 個樣本，**全部落在 `loop.zsh`**——`--launch` 不追子行程 |

要讓單一行程跑得夠久就得放大語料，而語料必須在記憶體裡；在記憶體吃緊的機器上，把 RAM
disk 撐大會擾動的正是要量的配置器與 page fault 行為。

**所以先量時間、確認差距存在，再談 profile。** profile 一個不存在的差距是浪費，而且
更糟——它一定會找到「某個最花時間的函式」，然後那個函式會被當成成因。

All four sampling approaches above fail on macOS, because the target runs about 0.17 s.
Establish that a gap exists before profiling one: a profiler always returns some hottest
function, and that function then gets mistaken for the cause.

---

## 目前的資料說了什麼 / What the current rows say

`extract_shapes.csv2` 中各平台最新的一組，同樣三種形狀、同樣的腳本（swift_tar / 參照）：

| 形狀 | macOS（`20261022-181622`，RAM disk，load 1.97，2026-10-22） | Linux (QEMU aarch64，`20261022-115531`，`/tmp/extract-shapes`，load 0.52，2026-10-22) |
|---|---|---|
| 20 × 8 MB | 34 / 73 ms = **0.47×** | 24 / 27 ms = **0.89×** |
| 200 × 800 KB | 53 / 89 ms = **0.60×** | 47 / 28 ms = **1.68×** |
| 2000 × 80 KB | 84 / 194 ms = **0.43×** | 51 / 38 ms = **1.34×** |

比值 = swift_tar 毫秒 ÷ 參照毫秒，小於 1 表示 swift_tar 較快。
Ratio = swift_tar ms ÷ reference ms; below 1 means swift_tar is faster.

**差距是 Linux 專有的，而且在碎檔形狀。** 在 Linux 上 swift_tar 於 200 × 800 KB 與
2000 × 80 KB 慢 1.34–1.68 倍，於 20 × 8 MB 則較快（0.89×）；在 macOS 上它在三種形狀都
比 bsdtar 快（0.43–0.60×）。

**因此 profile 要在 Linux 上做，不是在 macOS 上。** 而那也剛好是可行的一端：guest 的
行程壽命與工具鏈都允許取樣，macOS 這邊不允許（見上方陷阱 4）。

**一個必須說出來的干擾項**：兩端的參照實作不同版本——macOS 是 bsdtar 3.5.3 /
libarchive 3.7.4，Linux 是 bsdtar 3.8.9 / libarchive 3.8.9。所以「平台」不是兩組數字
之間唯一的變數，libarchive 是 3.7.4 對 3.8.9。要把差距完全歸給平台，得先在同一個平台上
換掉參照版本再量一次。**這裡不做那個宣稱。**

The latest rows per platform, same script and shapes: the gap is Linux-specific and lies
in the fragmented shapes — 1.34x to 1.68x slower there on 200 × 800 KB and 2000 × 80 KB,
while 20 × 8 MB is faster (0.89x). On macOS swift_tar is faster than bsdtar on all three
shapes (0.43x to 0.60x). So profiling belongs on Linux, which is also the end where
sampling is feasible.

One confound stated plainly: the two references are different versions (bsdtar 3.5.3 /
libarchive 3.7.4 on macOS, 3.8.9 / 3.8.9 on Linux), so platform is not the only variable
between the two columns. No claim is made here that it is.

---

## 已完成的量測 / Measurements taken

- [`pgo-linux-20260906.md`](pgo-linux-20260906.md) — Linux 的逐函式計數(LLVM PGO)。
  結論是**否定的**:那些時間不在 swift_tar 自己的 Swift 程式碼裡。解開 160 MB 只讓
  被儀器化的區塊執行 21,743 次,`readExactly` 全場 63 次,**沒有任何計數隨位元組數
  成長**。選 PGO 而非取樣,是因為計數與機器負載無關。
  Per-function counts on Linux. A negative result: the time is not in swift_tar's own
  Swift code — 21,743 instrumented counter increments for 160 MB, and nothing that
  scales with bytes. PGO was chosen over sampling because counts are load-independent.
